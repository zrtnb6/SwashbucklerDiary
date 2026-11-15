import Foundation

/// 公式的轻量排版。
///
/// 完整的 LaTeX 引擎体积与维护成本都远超这个项目的需要，这里做的是
/// 「符号替换 + 上下标」的近似排版：`E = mc^2` 会渲染成 E = mc²，
/// `H_2O` 渲染成 H₂O。原始 LaTeX 仍然可复制，不影响数据完整性。
enum MathRender {
    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ", "a": "ᵃ", "b": "ᵇ",
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "o": "ₒ", "x": "ₓ", "n": "ₙ", "i": "ᵢ",
    ]

    private static let symbols: [(String, String)] = [
        ("\\times", "×"), ("\\div", "÷"), ("\\pm", "±"), ("\\mp", "∓"), ("\\cdot", "·"),
        ("\\leq", "≤"), ("\\le", "≤"), ("\\geq", "≥"), ("\\ge", "≥"),
        ("\\neq", "≠"), ("\\ne", "≠"), ("\\approx", "≈"), ("\\equiv", "≡"),
        ("\\infty", "∞"), ("\\partial", "∂"), ("\\nabla", "∇"),
        ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"),
        ("\\epsilon", "ε"), ("\\zeta", "ζ"), ("\\eta", "η"), ("\\theta", "θ"),
        ("\\lambda", "λ"), ("\\mu", "μ"), ("\\nu", "ν"), ("\\xi", "ξ"),
        ("\\pi", "π"), ("\\rho", "ρ"), ("\\sigma", "σ"), ("\\tau", "τ"),
        ("\\phi", "φ"), ("\\chi", "χ"), ("\\psi", "ψ"), ("\\omega", "ω"),
        ("\\Delta", "Δ"), ("\\Sigma", "Σ"), ("\\Omega", "Ω"), ("\\Pi", "Π"),
        ("\\sum", "∑"), ("\\prod", "∏"), ("\\int", "∫"), ("\\oint", "∮"),
        ("\\sqrt", "√"), ("\\rightarrow", "→"), ("\\to", "→"), ("\\Rightarrow", "⇒"),
        ("\\leftarrow", "←"), ("\\Leftarrow", "⇐"), ("\\leftrightarrow", "↔"),
        ("\\in", "∈"), ("\\notin", "∉"), ("\\subset", "⊂"), ("\\cup", "∪"), ("\\cap", "∩"),
        ("\\forall", "∀"), ("\\exists", "∃"), ("\\angle", "∠"), ("\\degree", "°"),
        ("\\left", ""), ("\\right", ""), ("\\quad", "  "), ("\\,", " "),
    ]

    static func prettify(_ latex: String) -> String {
        var text = latex
        for (pattern, symbol) in symbols {
            text = text.replacingOccurrences(of: pattern, with: symbol)
        }
        text = text.replacingOccurrences(of: "frac", with: "")

        text = applyScript(text, marker: "^", map: superscripts)
        text = applyScript(text, marker: "_", map: subscripts)
        text = text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return text
    }

    private static func applyScript(_ text: String, marker: Character, map: [Character: Character]) -> String {
        var result = ""
        var iterator = Array(text)
        var index = 0
        while index < iterator.count {
            let char = iterator[index]
            if char == marker, index + 1 < iterator.count {
                if iterator[index + 1] == "{" {
                    // ^{...}
                    var end = index + 2
                    var inner = ""
                    while end < iterator.count, iterator[end] != "}" {
                        if let mapped = map[iterator[end]] {
                            inner.append(mapped)
                        } else {
                            inner.append(iterator[end])
                        }
                        end += 1
                    }
                    result += inner
                    index = min(end + 1, iterator.count)
                    continue
                } else if let mapped = map[iterator[index + 1]] {
                    result.append(mapped)
                    index += 2
                    continue
                }
            }
            result.append(char)
            index += 1
        }
        return result
    }
}
