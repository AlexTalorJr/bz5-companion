# BZ5 Companion v3

Android-приложение мониторинга Toyota BZ5 с **физически откалиброванной моделью**.

## Что нового в v3

### 🎯 Реальные физические единицы
- **Мощность зарядки в кВт** в реальном времени (вычисляется из BMS counter 0B00)
- **Lifetime energy charged** (суммарно получено из розетки за всю жизнь машины)
- **Range estimate** в км до пустой батареи (с учётом среднего расхода 14.4 кВт·ч/100км)
- **Trip energy** — точно сколько кВт·ч ушло на текущую поездку
- **ETA до 100%** на зарядке

### Калибровка
Все формулы откалиброваны на реальной зарядной сессии 2.1 кВт + паспорт Toyota:

```
Battery capacity:    65.28 kWh (datasheet)
Charge counter:      1 unit ≈ 45.6 Wh (BMS DID 0B00)
Avg consumption:     144 Wh/km (14.4 kWh/100km from dashboard)
```

## Сборка APK

```bash
git init && git add . && git commit -m "BZ5 v3"
gh repo create bz5-companion --private --source=. --push
# Подождать 5-7 минут → Actions → Artifacts → APK
```

## Скрины

### Dashboard
- Огромный SOC с цветовой индикацией
- Range estimate справа
- 6 metric cards: SOH, Battery temp, Odometer, Range, Lifetime energy, Gear
- Charging banner (когда подключён кабель) — показывает кВт + ETA до 100%
- Trip card с потраченным kWh за поездку
- Cells balance (20 ячеек гистограмма)
- **Calibration footer** — открыто показывает на чём базируются расчёты

### Cells screen
- Heatmap всех 20 cell voltages
- Цветовая шкала по min/max
- Оценка балансировки

### History
- Все поездки в SQLite
- Время, км, потраченный SOC, samples count

### ECUs Explorer
- 30 ECU автомобиля
- Подробные DID-ы для: BMS, VCU, Pack Monitor, Charger, GPS, Gateway

## Технические детали

**Architecture**: Flutter 3.24, Drift SQLite, flutter_blue_plus, Material 3.

**ECU polling**:
- BMS (790) — главный источник данных
- VCU (791) — odometer, gear
- Pack Monitor (740) — pack voltage (cached values)
- Charger (782) — connection state
- Gateway (702) — secondary

**Database tables**:
- Trips (id, started_at, ended_at, start/end SOC, start/end odo, sample_count)
- Samples (id, trip_id, timestamp, ecu_tx, did, raw_hex, numeric, text)
- Snapshots (id, captured_at, soc, soh, temp, cells, odometer)

## License

MIT.
