//! 访问码的生成与校验（纯逻辑）。
//!
//! 本模块不碰文件、管道或 Windows API，单元测试可以在任意平台运行。
//! rotate 码固定 6 位纯数字；fixed 码由用户输入，6–32 位 ASCII 字母或数字。

/// rotate 模式访问码长度。
pub const ROTATE_LEN: usize = 6;
/// 固定访问码最短长度。
pub const FIXED_MIN_LEN: usize = 6;
/// 固定访问码最长长度。
pub const FIXED_MAX_LEN: usize = 32;

const DIGITS: u32 = 1_000_000;

/// 生成 6 位纯数字访问码。
///
/// 用 getrandom 取 32 位随机数，按 `2^32 / 10^6` 的整数倍做拒绝采样，
/// 避免 `% 1_000_000` 带来的低位偏置；成功后才格式化成 6 位（含前导零）。
pub fn generate_rotate() -> Result<String, String> {
    loop {
        let mut buf = [0u8; 4];
        getrandom::getrandom(&mut buf).map_err(|_| "生成随机访问码失败".to_string())?;
        let value = u32::from_le_bytes(buf);
        let space = u64::from(u32::MAX) + 1;
        let limit = space - (space % u64::from(DIGITS));
        if u64::from(value) < limit {
            return Ok(format!("{:06}", value % DIGITS));
        }
    }
}

/// 是否为 rotate 模式的合法码：正好 6 位 ASCII 数字。
pub fn is_rotate_code(code: &str) -> bool {
    code.len() == ROTATE_LEN && code.bytes().all(|b| b.is_ascii_digit())
}

/// 校验固定访问码。错误信息会直接回给控制台，不得带出用户输入内容。
pub fn validate_fixed(code: &str) -> Result<(), String> {
    if code.is_empty() {
        return Err("访问码不能为空".to_string());
    }
    if code.len() < FIXED_MIN_LEN {
        return Err(format!("访问码至少需要 {FIXED_MIN_LEN} 位"));
    }
    if code.len() > FIXED_MAX_LEN {
        return Err(format!("访问码最多 {FIXED_MAX_LEN} 位"));
    }
    if !code.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err("访问码只能包含字母或数字".to_string());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotate_code_has_six_digits() {
        for _ in 0..200 {
            let code = match generate_rotate() {
                Ok(code) => code,
                Err(err) => panic!("生成失败：{err}"),
            };
            assert_eq!(code.len(), ROTATE_LEN);
            assert!(code.bytes().all(|b| b.is_ascii_digit()));
            assert!(is_rotate_code(&code));
        }
    }

    #[test]
    fn rotate_code_allows_leading_zero() {
        // 直接检查格式化规则：000000 也是合法六位码；实际生成是否出现前导零由随机性决定。
        assert!(is_rotate_code("000000"));
    }

    #[test]
    fn fixed_accepts_alnum_of_allowed_length() {
        assert!(validate_fixed("482916").is_ok());
        assert!(validate_fixed("Abc123").is_ok());
        assert!(validate_fixed("0123456789abcdefABCDEF01234567").is_ok());
    }

    #[test]
    fn fixed_rejects_empty_short_long_and_symbols() {
        assert!(validate_fixed("").is_err());
        assert!(validate_fixed("12345").is_err());
        assert!(validate_fixed("123456789012345678901234567890123").is_err());
        assert!(validate_fixed("123 456").is_err());
        assert!(validate_fixed("123-456").is_err());
        assert!(validate_fixed("访问码一二三四五").is_err());
        assert!(validate_fixed("12345é").is_err());
    }

    #[test]
    fn rotate_code_rejects_non_six_digit_forms() {
        assert!(!is_rotate_code("12345"));
        assert!(!is_rotate_code("1234567"));
        assert!(!is_rotate_code("12a456"));
        assert!(!is_rotate_code("１２３４５６"));
        assert!(!is_rotate_code(""));
    }

    #[test]
    fn rotate_digits_are_roughly_uniform() {
        // 6000 个样本、10 个数字：期望每个 600。粗测只要求落在 400–800，避免偶发抖动。
        let mut counts = [0usize; 10];
        for _ in 0..6000 {
            let code = match generate_rotate() {
                Ok(code) => code,
                Err(err) => panic!("生成失败：{err}"),
            };
            for byte in code.bytes() {
                counts[(byte - b'0') as usize] += 1;
            }
        }
        for (digit, count) in counts.iter().enumerate() {
            assert!(
                (400..=800).contains(count),
                "数字 {digit} 出现 {count} 次，偏离均匀分布"
            );
        }
    }
}
