import Foundation

enum InputModel: String, CaseIterable, Identifiable {
    case ice
    case wanxiang

    var id: String { rawValue }
    static let preferenceKey = "selectedInputModel"
    static let revisionKey = "inputModelRevision"

    static var selected: InputModel {
        let raw = SharedSettings.defaults.string(forKey: preferenceKey)
        return InputModel(rawValue: raw ?? "") ?? .ice
    }
}

enum RimeSchema {
    // Compiled for Pinyin reverse lookup, including in older imported profiles.
    static let stroke = "stroke"
    static let full = "luna_pinyin_simp"
    static let keypad = "luna_pinyin_t9"
    static let flypy = "double_pinyin_flypy"
    // Preference IDs also identify existing learning and gesture-layout data.
    static let doubleLayouts = [flypy, "double_pinyin", "double_pinyin_mspy", "double_pinyin_abc", "double_pinyin_pyjj", "double_pinyin_st"]
    static let presets = [full: "wanxiang", keypad: "wanxiang_t9", flypy: "wanxiang_flypy",
                          "double_pinyin": "wanxiang_zrm", "double_pinyin_mspy": "wanxiang_mspy",
                          "double_pinyin_abc": "wanxiang_abc", "double_pinyin_pyjj": "wanxiang_pyjj", "double_pinyin_st": "wanxiang_st"]
    static let icePresets = [full: "ice", keypad: "ice_t9", flypy: "ice_flypy",
                             "double_pinyin": "ice_zrm", "double_pinyin_mspy": "ice_mspy",
                             "double_pinyin_abc": "ice_abc", "double_pinyin_pyjj": "ice_pyjj", "double_pinyin_st": "ice_st"]
    static let wanxiangMarkers = [full: "Ⅰ", "double_pinyin": "Ⅱ", flypy: "Ⅲ", "double_pinyin_mspy": "Ⅳ",
                                  "double_pinyin_abc": "Ⅵ", "double_pinyin_pyjj": "Ⅷ"]
    static var titles: [String: String] { [
        "luna_pinyin_simp": L10n.fullPinyin, "luna_pinyin_t9": L10n.keypadPinyin,
        flypy: L10n.flypy, "double_pinyin": L10n.ziranma, "double_pinyin_mspy": L10n.microsoftDoublePinyin,
        "double_pinyin_abc": L10n.intelligentABC, "double_pinyin_pyjj": L10n.pinyinJiajia, "double_pinyin_st": L10n.stoneDoublePinyin
    ] }

    static func isDoublePinyin(_ id: String) -> Bool {
        id == "double_pinyin" || id.hasPrefix("double_pinyin_")
    }

    static func tapPreset(_ id: String, model: InputModel = .ice) -> String? {
        guard id == keypad || (isDoublePinyin(id) && id != flypy) else { return nil }
        return model == .wanxiang ? presets[id] : icePresets[id]
    }

    static func usesSemicolon(_ id: String) -> Bool {
        id == "double_pinyin_mspy" || id == "double_pinyin_st"
    }
}
