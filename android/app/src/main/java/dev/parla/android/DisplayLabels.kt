package dev.parla.android

import java.text.NumberFormat

// Display labels only. Persisted values and provider model IDs stay unchanged.
internal fun outputLabel(value: String) = when(value) {
    "cleanup" -> "Clean up speech"
    "raw" -> "As spoken"
    "selectedPreset" -> "Use a saved preset"
    else -> "Choose an output"
}
internal fun styleLabel(value: String) = when(value) {
    "standard" -> "Standard"
    "conversational" -> "Conversational"
    "formal" -> "Formal"
    else -> "Use default style"
}
internal fun cleanupLabel(value: String) = when(value) {
    "on" -> "On"
    "off" -> "Off"
    else -> "Use default setting"
}
internal fun presetLabel(value: String) = if(value == "translation") "Translate" else "Rewrite"
internal fun speechModelLabel(value: String) = when(value) {
    "" -> "Use default model"
    "base.en" -> "Base · English"
    "small.en-q5_1" -> "Small · English"
    "large-v3-turbo-q5_0" -> "Large v3 Turbo · Multilingual"
    else -> "Choose a speech model"
}
internal fun providerLabel(value: String) = when(value) {
    "anthropic" -> "Anthropic"
    "openai-compatible" -> "OpenAI compatible"
    else -> "Choose a provider"
}
internal fun screenLabel(route: String) = when(route) {
    "Practice" -> "Try it here"
    "parla Bubble Size" -> "Voice control size"
    "parla Bubble Opacity" -> "Voice control opacity"
    else -> route
}
internal fun fileSizeLabel(bytes: Long): String {
    val (divisor, unit) = when {
        bytes >= 1_000_000_000 -> 1_000_000_000.0 to "GB"
        bytes >= 1_000_000 -> 1_000_000.0 to "MB"
        else -> 1_000.0 to "KB"
    }
    val number = NumberFormat.getNumberInstance().apply { maximumFractionDigits = 1 }
    return "${number.format(bytes / divisor)} $unit"
}
