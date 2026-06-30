// === COMPANION-AUTHORED (editable) — DiLink platform registry, patch +107 ===
// NOT vendored. Data-driven registry of known DiLink platforms (BZ3, BZ5,
// future BYD) + a runtime extraction-shape probe as the fallback for an
// UNKNOWN DiLink head unit. This is "Вариант 2" (profiles + runtime shape
// detection): a recognised model resolves by its profile; an unrecognised
// one self-lifts on the correct engine by probing whether the framework
// event object exposes FIELDS (BZ5-style) or only GETTERS (BZ3-style).
//
// The fork is by SHAPE, never by `if (model == BZ3)`. A new model is one
// new DiLinkProfile row; no engine code changes.
//
// Confirmed markers (from real hardware, recon page "BZ3 hal"):
//   BZ5: fingerprint contains "TOYOTA SPACE" / DiLink5.0, SDK 32,
//        SM7325 (Snapdragon 778G), event payload via FIELDS, BYDCrossFeatureIds present.
//   BZ3: fingerprint "qti/trinket/trinket:10/...", SDK 29, SM6115 (trinket),
//        event payload via GETTERS only (fields closed to reflection),
//        BYDCrossFeatureIds class_not_found.
package com.bz5companion.bz5_companion.hal

import android.util.Log

/** How a platform's framework event object exposes its payload. */
enum class EngineKind { FIELDS, GETTERS }

/**
 * One known DiLink platform.
 *
 * @param id              stable short id, e.g. "BZ5", "BZ3".
 * @param displayName     human label for honesty UI.
 * @param engineKind      FIELDS → Bz5EngineAdapter; GETTERS → Bz3EngineAdapter.
 * @param unconditionalEngine  PER-PROFILE Engine-target safety. When true the
 *                        consumer should ensure the Engine device is in the
 *                        target list even if streamingTargets()'s fid-gate
 *                        would drop it. Both known profiles are FALSE: recon
 *                        q1 (v0.10.80) confirmed BYDAutoFeatureIds resolves on
 *                        BZ3 (Engine inner-class present) so the gate keeps
 *                        Engine. This flag is here for a future unknown DiLink
 *                        where the catalog might not resolve — NOT a global.
 * @param hasCrossFeatureIds  whether android.cross.BYDCrossFeatureIds resolves
 *                        (BZ5 yes, BZ3 no). Advisory for cross-fid consumers.
 * @param matchScore      multi-signal confidence this profile matches the live
 *                        hardware. Sum of available signals; absence of any one
 *                        signal does not sink the match (so BZ5 still matches
 *                        even though its VIN reflection throws in practice).
 */
data class DiLinkProfile(
    val id: String,
    val displayName: String,
    val engineKind: EngineKind,
    val unconditionalEngine: Boolean,
    val hasCrossFeatureIds: Boolean,
    val fingerprintNeedle: String,
    val expectedSdk: Int,
    val vinWmiNeedles: List<String> = emptyList()
) {
    /**
     * Score this profile against live hardware signals. Higher = better.
     *   +3  fingerprint needle present (strongest single signal)
     *   +1  SDK matches expected
     *   +1  VIN WMI prefix matches (WEAK/optional — VIN reflection is known
     *       to fail on BZ5 hardware, so this can only ever add, never gate)
     * A non-zero score means "recognised". Zero ⇒ fall back to shape probe.
     */
    fun matchScore(fingerprint: String?, sdk: Int?, vin: String?): Int {
        var s = 0
        if (!fingerprint.isNullOrBlank() &&
            fingerprint.contains(fingerprintNeedle, ignoreCase = true)) s += 3
        if (sdk != null && sdk == expectedSdk) s += 1
        if (!vin.isNullOrBlank() && vinWmiNeedles.any {
                vin.startsWith(it, ignoreCase = true)
            }) s += 1
        return s
    }
}

object DiLinkProfiles {

    private const val TAG = "DiLinkProfiles"

    // Registry. A new model = +1 row here, nothing else.
    val profiles: List<DiLinkProfile> = listOf(
        DiLinkProfile(
            id = "BZ5",
            displayName = "BYD BZ5 (DiLink5.0)",
            engineKind = EngineKind.FIELDS,
            unconditionalEngine = false,
            hasCrossFeatureIds = true,
            fingerprintNeedle = "TOYOTA SPACE",
            expectedSdk = 32
            // VIN WMI intentionally empty: getRealAutoVIN/getAutoVIN throw on
            // this firmware (BydVinDetector field test), so VIN cannot be a
            // reliable BZ5 signal. Fingerprint + SDK carry the match.
        ),
        DiLinkProfile(
            id = "BZ3",
            displayName = "BYD BZ3 (trinket)",
            engineKind = EngineKind.GETTERS,
            unconditionalEngine = false,
            hasCrossFeatureIds = false,
            fingerprintNeedle = "trinket",
            expectedSdk = 29
        )
    )

    /**
     * Result of platform selection.
     * @param profile   matched profile, or null when selection fell back to a
     *                  bare shape probe (unknown DiLink).
     * @param engineKind the engine shape to instantiate (always set).
     * @param reason    how we decided: "override" | "match:<id>" | "probe".
     */
    data class Selection(
        val profile: DiLinkProfile?,
        val engineKind: EngineKind,
        val reason: String
    ) {
        /** Stable id for honesty UI: profile id, or "UNKNOWN" on a probe path. */
        val platformId: String get() = profile?.id ?: "UNKNOWN"
        val displayName: String get() = profile?.displayName ?: "Unrecognised DiLink"
    }

    /**
     * Pick the platform for the live hardware.
     *   1. explicit override id (advanced setting) wins.
     *   2. else best non-zero matchScore across the registry.
     *   3. else probeShape() — FIELDS vs GETTERS — so an unknown DiLink still
     *      self-lifts on the right engine instead of failing silently.
     *
     * @param overrideId  optional advanced-setting override (profile id).
     * @param fingerprint Build.FINGERPRINT.
     * @param sdk         Build.VERSION.SDK_INT.
     * @param vin         best-effort VIN (may be null/empty — see note above).
     */
    fun selectProfile(
        overrideId: String?,
        fingerprint: String?,
        sdk: Int?,
        vin: String?
    ): Selection {
        // 1. override
        if (!overrideId.isNullOrBlank()) {
            val p = profiles.firstOrNull { it.id.equals(overrideId, ignoreCase = true) }
            if (p != null) {
                Log.i(TAG, "selectProfile: override -> ${p.id}")
                return Selection(p, p.engineKind, "override")
            }
            Log.w(TAG, "selectProfile: override '$overrideId' not in registry; ignoring")
        }

        // 2. best match
        val scored = profiles
            .map { it to it.matchScore(fingerprint, sdk, vin) }
            .filter { it.second > 0 }
            .sortedByDescending { it.second }
        if (scored.isNotEmpty()) {
            val (p, score) = scored.first()
            Log.i(TAG, "selectProfile: match ${p.id} (score=$score, fp='${fingerprint?.take(40)}', sdk=$sdk)")
            return Selection(p, p.engineKind, "match:${p.id}")
        }

        // 3. shape probe fallback
        val kind = probeShape()
        Log.w(TAG, "selectProfile: no registry match; shape probe -> $kind")
        return Selection(null, kind, "probe")
    }

    /** Map an engine kind to an adapter factory. */
    fun selectEngine(
        kind: EngineKind,
        ctx: android.content.Context,
        sink: TelemetrySink,
        targets: List<TargetSpec>
    ): HalEngine = when (kind) {
        EngineKind.FIELDS -> Bz5EngineAdapter(ctx, sink, targets)
        EngineKind.GETTERS -> Bz3EngineAdapter(ctx, sink, targets)
    }

    /**
     * Runtime extraction-shape probe for an UNKNOWN DiLink. Decides FIELDS vs
     * GETTERS WITHOUT a live event by inspecting the framework event class
     * itself:
     *   - if BYDAutoEvent exposes the BZ5 instance fields (mDeviceSubType /
     *     mIntValue / ...) to reflection → FIELDS.
     *   - else (fields closed, only getEventType/getValue/... present, the
     *     BZ3 condition recon proved at p098) → GETTERS.
     * Defaults to GETTERS on any failure: the 1-arg getter engine is the more
     * permissive of the two (it does not require the 2-arg registerListener
     * overload that was the original BZ3 wall), so an unknown unit is more
     * likely to deliver under GETTERS than FIELDS.
     */
    fun probeShape(): EngineKind {
        val eventClassNames = listOf(
            "android.hardware.bydauto.BYDAutoEvent",
            "android.hardware.bydauto.event.BYDAutoEvent"
        )
        for (cn in eventClassNames) {
            val cls = try { Class.forName(cn) } catch (_: Throwable) { null } ?: continue
            // BZ5 exposes these as instance fields; BZ3 has them closed.
            val fieldNames = try {
                cls.declaredFields.map { it.name }.toSet()
            } catch (_: Throwable) { emptySet() }
            val hasBz5Fields = fieldNames.any {
                it == "mDeviceSubType" || it == "mIntValue" ||
                    it == "mDoubleValue" || it == "mBufData"
            }
            if (hasBz5Fields) {
                Log.i(TAG, "probeShape: $cn exposes BZ5 fields -> FIELDS")
                return EngineKind.FIELDS
            }
            // confirm the BZ3 getter surface exists before committing
            val methodNames = try {
                cls.methods.map { it.name }.toSet()
            } catch (_: Throwable) { emptySet() }
            val hasGetters = methodNames.contains("getEventType") &&
                (methodNames.contains("getValue") || methodNames.contains("getBufferData"))
            if (hasGetters) {
                Log.i(TAG, "probeShape: $cn getter-only -> GETTERS")
                return EngineKind.GETTERS
            }
        }
        Log.w(TAG, "probeShape: event class shape inconclusive -> default GETTERS")
        return EngineKind.GETTERS
    }
}
