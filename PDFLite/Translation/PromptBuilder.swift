import Foundation

/// Builds the OpenAI-compatible chat-completions message array. Phase 3 keeps this hard-coded
/// and pure: no user-editable prompt, no markdown fences, no per-request system prompt swaps.
enum PromptBuilder {
    static func messages(sourceText: String,
                         targetLanguage: String = TranslationConfig.defaultTargetLanguage)
        -> [[String: String]]
    {
        // No `\n` escapes inside this literal: in a Swift string they become real newlines, which
        // once put an empty line inside a backtick pair in rule 5. Describe blank lines in words.
        let system = """
        你是一名学术论文翻译助手。请把用户提供的英文/其它语种学术文本翻译为\(targetLanguage)，并严格遵守：
        1. 只输出译文，不要任何解释、引言、提示语或免责声明。
        2. 不要使用 markdown 代码块、引号或前后缀。
        3. 保留公式、变量名、引用编号（如 [12]、(Chen et al., 2023)）和英文缩写（如 LLM、KV cache、RoPE）。
        4. 数字和单位使用阿拉伯数字与原文单位，不要换算。
        5. 严格保留原文段落结构：原文中的空行（连续两个换行符）就是段落分隔符，译文必须在对应位置同样保留一个空行，不要把多个段落合并成一段；段落内可以自然换行。
        """

        let user = """
        请翻译以下文本：

        \(sourceText)
        """

        return [
            ["role": "system", "content": system],
            ["role": "user", "content": user]
        ]
    }
}
