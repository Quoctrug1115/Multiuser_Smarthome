use std::collections::HashMap;

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
pub fn extract_habit_suggestions(records: Vec<(u32, String)>, total_days: usize) -> Vec<(u32, String, f64)> {
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
        if confidence >= 0.80 { // Ngưỡng 80%
            suggestions.push((hour, action, confidence));
        }
    }

    suggestions
}