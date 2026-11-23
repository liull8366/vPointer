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
 * 目前是**预留页**：具体功能待定，这里先放一个 root 可用性自检，
 * 方便后续把需要 root 的能力（守护脚本、权限直授、su 命令面板等）长在这页上。
 *
 * 版式与其它页一致：标题 → 灰字说明 → 状态 → 可滚动内容 → 底部整宽主按钮。
 */
@Composable
fun RootScreen(
    check: RootCheck,
    detail: String,
    onCheck: () -> Unit
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
            modifier = Modifier.padding(bottom = 16.dp)
        )

        Text(
            text = "预留页 —— 具体功能待定。这里先提供一次 root 可用性自检（执行 su -c id），" +
                "后续需要 root 的能力会落在这一页。",
            fontSize = 14.sp,
            color = Color.Gray,
            modifier = Modifier.padding(bottom = 16.dp)
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

        if (detail.isNotEmpty()) {
            Text(
                text = detail,
                fontSize = 12.sp,
                fontFamily = FontFamily.Monospace,
                color = Color.Gray,
                modifier = Modifier.padding(top = 8.dp)
            )
        }

        HorizontalDivider(modifier = Modifier.padding(vertical = 16.dp))

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .verticalScroll(rememberScrollState())
        ) {
            Text(
                text = "后续功能（待定）",
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(bottom = 8.dp)
            )
            Text(
                text = "· 守护脚本 / 开机自启（root 拉起前台服务）\n" +
                    "· 悬浮窗、电池白名单等权限一键直授（appops / deviceidle）\n" +
                    "· 常用 su 命令面板与执行结果回显\n" +
                    "· 其它需要 root 的调试开关",
                fontSize = 13.sp,
                color = Color.Gray,
                lineHeight = 20.sp
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
