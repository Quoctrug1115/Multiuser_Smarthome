
/// Thuật toán Z-Score phát hiện chỉ số cảm biến vượt ngưỡng bất thường
/// Z = (x - mean) / std_dev
pub fn detect_sensor_anomaly(values: &[f64], current_value: f64) -> Option<(String, f64)> {
    if values.len() < 5 {
        return None; // Chưa đủ mẫu dữ liệu để tính toán thống kê
    }

    let count = values.len() as f64;
    let mean: f64 = values.iter().sum::<f64>() / count;
    
    let variance: f64 = values.iter().map(|value| {
        let diff = mean - value;
        diff * diff
    }).sum::<f64>() / count;

    let std_dev = variance.sqrt();

    if std_dev == 0.0 {
        return None;
    }

    let z_score = (current_value - mean).abs() / std_dev;

    // Nếu Z-score > 3.0 (vượt ngoài độ lệch chuẩn 99.7%), coi là bất thường nghiêm trọng
    if z_score > 3.0 {
        if current_value > mean {
            Some(("HIGH_SPIKE".to_string(), z_score))
        } else {
            Some(("LOW_DROP".to_string(), z_score))
        }
    } else {
        None
    }
}

/// Kiểm tra xem thời điểm hiện tại có nằm trong khung giờ bất thường (VD: 23:00 - 05:00) hay không
pub fn is_unusual_time_window(hour: u32) -> bool {
    hour >= 23 || hour <= 5
}