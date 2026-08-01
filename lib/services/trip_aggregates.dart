// v0.1.86+185 — ЧИСТЫЙ РАСЧЁТ ПРОИЗВОДНЫХ ВЕЛИЧИН ПОЕЗДКИ.
//
// ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ.
//
// Этот расчёт лежал в `connection.dart` ДВАЖДЫ — в
// `_finalizeTripFromLastKnown` и в пути чистого завершения, — двумя
// копиями, совпадавшими посимвольно. Пока копии две, они совпадают
// случайно: правка в одной не видна из другой, и первое же расхождение
// даст две разные поездки из одних данных, молча. Фоновый строитель стал
// бы третьей копией.
//
// Поэтому расчёт вынесен сюда целиком и зовётся тремя путями: два живых
// в `connection.dart` и фоновый в `bg_trip_builder.dart`.
//
// ЧИСТОТА ЗДЕСЬ НЕ УКРАШЕНИЕ, А УСЛОВИЕ. Файл не импортирует ни Flutter,
// ни drift, ни модель машины — ничего. Он не читает базу, не смотрит на
// часы и не хранит состояния. Всё, что ему нужно, приходит параметрами,
// включая ёмкость батареи: политика (сколько кВт·ч в пакете) не
// принадлежит механизму (как поделить одно на другое). Ровно та же
// болезнь, что вылечена в этом патче у `detachFlutter`, только там она
// была в Kotlin.
//
// Побочный эффект чистоты: расчёт проверяется зеркалом на Python против
// настоящего экспорта, без сборки и без машины. Гейт BS1 стережёт
// отсутствие импортов.

/// Производные величины поездки. Каждое поле nullable: неизвестное
/// остаётся null и никогда не подменяется нулём (правило честности —
/// ноль километров и «неизвестно сколько километров» это разные вещи,
/// и на карточке они выглядят по-разному).
typedef TripDerived = ({
  double? distanceKm,
  double? energyUsedKwh,
  double? avgConsumptionKwh100km,
  double? avgMovingSpeedKmh,
  double? energyFromSocKwh,
});

/// Посчитать производные величины поездки.
///
/// Формулы перенесены из `connection.dart` БЕЗ ИЗМЕНЕНИЙ, включая пороги
/// и направления сравнений:
///
/// * дистанция — только при СТРОГОМ росте одометра. Равенство отбрасывается
///   намеренно: одометр целочисленный по 0.1 км, и «столько же» значит
///   «машина не ехала», а не «проехала ноль»;
/// * энергия — только при падении SOC. Рост SOC внутри поездки означает
///   зарядку или сбой датчика, и ни то ни другое не расход;
/// * расход — только на дистанции больше 100 метров. На меньшей делитель
///   превращает шум одометра в тысячи кВт·ч на сотню.
TripDerived computeTripDerived({
  required double? startOdoKm,
  required double? endOdoKm,
  required double? startSocPct,
  required double? endSocPct,
  required double? startSocPrecisePct,
  required double? endSocPrecisePct,
  required double speedSum,
  required int speedSamples,
  required double batteryCapacityKwh,
}) {
  double? distanceKm;
  if (startOdoKm != null && endOdoKm != null && endOdoKm > startOdoKm) {
    distanceKm = endOdoKm - startOdoKm;
  }
  double? energyUsedKwh;
  if (startSocPct != null && endSocPct != null && startSocPct > endSocPct) {
    energyUsedKwh = (startSocPct - endSocPct) * batteryCapacityKwh / 100.0;
  }
  double? avgConsumptionKwh100km;
  if (distanceKm != null && energyUsedKwh != null && distanceKm > 0.1) {
    avgConsumptionKwh100km = (energyUsedKwh / distanceKm) * 100.0;
  }
  double? avgMovingSpeedKmh;
  if (speedSamples > 0) {
    avgMovingSpeedKmh = speedSum / speedSamples;
  }
  double? energyFromSocKwh;
  if (startSocPrecisePct != null &&
      endSocPrecisePct != null &&
      startSocPrecisePct > endSocPrecisePct) {
    energyFromSocKwh =
        (startSocPrecisePct - endSocPrecisePct) * batteryCapacityKwh / 100.0;
  }
  return (
    distanceKm: distanceKm,
    energyUsedKwh: energyUsedKwh,
    avgConsumptionKwh100km: avgConsumptionKwh100km,
    avgMovingSpeedKmh: avgMovingSpeedKmh,
    energyFromSocKwh: energyFromSocKwh,
  );
}
