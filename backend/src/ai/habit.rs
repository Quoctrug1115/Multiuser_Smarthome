use std::collections::{HashMap, HashSet};
use uuid::Uuid;

pub struct ActionPattern {
    pub hour: u32,
    pub action: String,
    pub count: usize,
    pub total_days: usize,
}

impl ActionPattern {
    /// Tính độ tin cậy của thói quen: Confidence = (Số lần bật ở khung giờ / Tổng số ngày)
    pub fn calculate_confidence(&self) -> f64 {
        if self.total_days == 0 {
            return 0.0;
        }
        (self.count as f64) / (self.total_days as f64)
    }
}

/// Tìm các thói quen lặp đi lặp lại đạt ngưỡng tin cậy >= 80%
pub fn extract_habit_suggestions(
    records: Vec<(u32, String)>,
    total_days: usize,
) -> Vec<(u32, String, f64)> {
    let mut frequency_map: HashMap<(u32, String), usize> = HashMap::new();

    for (hour, action) in records {
        *frequency_map.entry((hour, action)).or_insert(0) += 1;
    }

    let mut suggestions = Vec::new();

    for ((hour, action), count) in frequency_map {
        let pattern = ActionPattern {
            hour,
            action: action.clone(),
            count,
            total_days,
        };

        let confidence = pattern.calculate_confidence();
        if confidence >= 0.80 {
            suggestions.push((hour, action, confidence));
        }
    }

    suggestions
}

#[derive(Debug, Clone)]
pub struct ControlHistoryRecord {
    pub owner_id: Uuid,
    pub device_id: Uuid,
    pub device_name: String,
    pub action: String,    // "ON" | "OFF"
    pub hour: u32,         // 0..23
    pub minute_slot: u32,  // 0 hoặc 30
    pub day_key: String,   // YYYY-MM-DD
}

#[derive(Debug, Clone)]
pub struct HabitRecommendation {
    pub owner_id: Uuid,
    pub device_id: Uuid,
    pub device_name: String,
    pub action: String,
    pub hour: u32,
    pub minute_slot: u32,
    pub repeat_days: usize,
    pub confidence_score: f64,
    pub cron_expression: String,
}

/// Khai phá thói quen điều khiển thiết bị lặp lại theo khung giờ 30 phút
pub fn mine_device_habits(
    records: &[ControlHistoryRecord],
    min_days: usize,
    min_confidence: f64,
) -> Vec<HabitRecommendation> {
    if records.is_empty() {
        return Vec::new();
    }

    // Tổng số ngày có phát sinh thao tác trên từng thiết bị
    let mut device_active_days: HashMap<(Uuid, Uuid), HashSet<String>> = HashMap::new();
    // Nhóm theo (owner_id, device_id, action, hour, minute_slot) -> tập các ngày khác nhau
    let mut slot_days: HashMap<(Uuid, Uuid, String, u32, u32), (String, HashSet<String>)> =
        HashMap::new();

    for rec in records {
        let act = rec.action.trim().to_uppercase();
        if act != "ON" && act != "OFF" {
            continue;
        }

        device_active_days
            .entry((rec.owner_id, rec.device_id))
            .or_default()
            .insert(rec.day_key.clone());

        let key = (
            rec.owner_id,
            rec.device_id,
            act,
            rec.hour,
            rec.minute_slot,
        );
        let entry = slot_days
            .entry(key)
            .or_insert_with(|| (rec.device_name.clone(), HashSet::new()));
        entry.1.insert(rec.day_key.clone());
    }

    let mut results = Vec::new();

    for ((owner_id, device_id, action, hour, minute_slot), (device_name, days)) in slot_days {
        let repeat_days = days.len();
        if repeat_days < min_days {
            continue;
        }

        let total_dev_days = device_active_days
            .get(&(owner_id, device_id))
            .map(|s| s.len().max(repeat_days))
            .unwrap_or(repeat_days);

        let raw_conf = (repeat_days as f64) / (total_dev_days as f64);
        // Kết hợp trọng số số ngày lặp lại để tránh nhiễu mẫu nhỏ
        let stability_bonus = ((repeat_days.min(7) as f64) / 7.0) * 0.15;
        let confidence_score = (raw_conf * 0.85 + stability_bonus).min(0.98);

        if confidence_score >= min_confidence {
            results.push(HabitRecommendation {
                owner_id,
                device_id,
                device_name,
                action,
                hour,
                minute_slot,
                repeat_days,
                confidence_score,
                cron_expression: format!("{} {} * * *", minute_slot, hour),
            });
        }
    }

    results.sort_by(|a, b| {
        b.confidence_score
            .partial_cmp(&a.confidence_score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    results
}