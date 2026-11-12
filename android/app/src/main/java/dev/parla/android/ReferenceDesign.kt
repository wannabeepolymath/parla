package dev.parla.android

import androidx.compose.material3.Typography
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

// APK TypeKt/ColorKt tokens. Provenance: evidence/reference/assets.json and docs/VISUAL-FIDELITY.md.
@OptIn(ExperimentalTextApi::class)
internal val Figtree = FontFamily(listOf(400, 500, 600, 700).flatMap { weight ->
    listOf(
        Font(R.font.figtree_variable_font_wght, FontWeight(weight), variationSettings = FontVariation.Settings(FontVariation.weight(weight))),
        Font(R.font.figtree_italic_variable_font_wght, FontWeight(weight), FontStyle.Italic, variationSettings = FontVariation.Settings(FontVariation.weight(weight))),
    )
})
internal val Garamond = FontFamily(
    Font(R.font.eb_garamond_variable_font_wght),
    Font(R.font.eb_garamond_italic_variable_font_wght, style = FontStyle.Italic),
)
internal val PageGray = Color(0xFFEEEEF0)
internal val SettingsGray = Color(0xFFF5F5F5)
internal val Primary800 = Color(0xFF6C358C)
internal val M3Gray = Color(0xFF49454F)
internal val Neutral500 = Color(0xFF7F7B81)
internal val BodyStyle = TextStyle(fontFamily = Figtree, fontWeight = FontWeight.Medium, fontSize = 16.sp, lineHeight = 24.sp)
internal val TranscriptStyle = BodyStyle.copy(fontSize = 18.sp, lineHeight = 24.sp, color = Color(0xFF312D37))
internal val ScreenTitleStyle = BodyStyle.copy(fontSize = 18.sp, lineHeight = 28.sp, fontWeight = FontWeight.SemiBold)
internal val NavLabelStyle = BodyStyle.copy(fontSize = 12.sp, lineHeight = 16.sp, letterSpacing = .5.sp)
internal val DayStyle = TextStyle(fontFamily = Garamond, fontSize = 36.sp, lineHeight = 42.sp)
internal val ParlaTypography = Typography(
    bodyLarge = BodyStyle, bodyMedium = BodyStyle, bodySmall = BodyStyle.copy(fontSize = 12.sp, lineHeight = 17.sp),
    titleLarge = ScreenTitleStyle, titleMedium = ScreenTitleStyle, titleSmall = BodyStyle.copy(fontWeight = FontWeight.SemiBold),
    labelLarge = BodyStyle.copy(fontWeight = FontWeight.SemiBold), labelMedium = NavLabelStyle, labelSmall = NavLabelStyle,
    headlineLarge = DayStyle, headlineMedium = DayStyle, headlineSmall = ScreenTitleStyle,
)
