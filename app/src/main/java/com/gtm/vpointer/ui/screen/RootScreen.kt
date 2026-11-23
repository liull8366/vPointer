package com.gtm.vpointer.ui.screen

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** root 自检状态 */
enum class RootCheck { UNKNOWN, CHECKING, GRANTED, DENIED }

/**
 * Root 权限页（第四个 Tab，排在「Lua 日志」右侧）。
 *
 * 定位：**对原版功能的增强**，不改原逻辑，只用 root 把「稳定运行」需要的手工步骤自动化：
 *   - `appops set … SYSTEM_ALERT_WINDOW allow`：免去手动点悬浮窗授权
 *   - `dumpsys deviceidle whitelist +包名`：加 Doze 白名单，后台不被轻易回收
 *
 * 不含守护脚本（按需求暂不做）。root 不可用时按钮会给出失败原因，原版功能仍可手动使用。
 */
@Composable
fun RootScreen(
    check: RootCheck,
    detail: String,
    message: String,
    onCheck: () -> Unit,
    onGrant: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
    ) {
        Text(
            text = "Root 权限",
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 12.dp)
        )

        Text(
            text = "用 root 给原版功能加一层保险：把「悬浮窗授权」和「电池白名单」一次做完。" +
                "不改原有服务逻辑，root 不可用时也不影响手动使用。",
            fontSize = 14.sp,
            color = Color.Gray,
            modifier = Modifier.padding(bottom = 12.dp)
        )

        val (statusText, statusColor) = when (check) {
            RootCheck.UNKNOWN -> "未检测" to Color.Gray
            RootCheck.CHECKING -> "检测中 …" to Color(0xFFFF9800)
            RootCheck.GRANTED -> "已获得 root" to Color(0xFF4CAF50)
            RootCheck.DENIED -> "未获得 root" to MaterialTheme.colorScheme.error
        }
        Text(
            text = "状态：$statusText",
            fontSize = 15.sp,
            fontWeight = FontWeight.Medium,
            color = statusColor
        )

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .verticalScroll(rememberScrollState())
        ) {
            if (detail.isNotEmpty()) {
                Text(
                    text = detail,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    color = Color.Gray,
                    modifier = Modifier.padding(top = 6.dp)
                )
            }

            HorizontalDivider(modifier = Modifier.padding(vertical = 14.dp))

            Text(
                text = "一键授权",
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(bottom = 6.dp)
            )
            Text(
                text = "执行：\nappops set com.gtm.vpointer SYSTEM_ALERT_WINDOW allow\n" +
                    "dumpsys deviceidle whitelist +com.gtm.vpointer",
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
                color = Color.Gray,
                modifier = Modifier.padding(bottom = 10.dp)
            )
            OutlinedButton(
                onClick = onGrant,
                enabled = check != RootCheck.CHECKING,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(46.dp)
            ) {
                Text("一键授权（悬浮窗 + 电池白名单）", fontSize = 15.sp)
            }

            if (message.isNotEmpty()) {
                Text(
                    text = message,
                    fontSize = 12.sp,
                    fontFamily = FontFamily.Monospace,
                    color = Color(0xFF2196F3),
                    modifier = Modifier.padding(top = 12.dp)
                )
            }

            Text(
                text = "说明：显示「未获得 root」时，请到 root 管理器（KernelSU / Magisk）给本应用授权，" +
                    "再回来点「重新检测」。授予后悬浮窗不再需要手点系统弹窗，服务也更不容易被 Doze 回收。",
                fontSize = 12.sp,
                color = Color.Gray,
                modifier = Modifier.padding(top = 14.dp)
            )
        }

        Spacer(modifier = Modifier.height(12.dp))

        Button(
            onClick = onCheck,
            enabled = check != RootCheck.CHECKING,
            modifier = Modifier
                .fillMaxWidth()
                .height(50.dp)
        ) {
            Text(
                text = if (check == RootCheck.UNKNOWN) "检测 root 权限" else "重新检测",
                fontSize = 16.sp
            )
        }
    }
}
