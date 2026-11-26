package com.gtm.vpointer.ui.screen

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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

/**
 * YOLO 自瞄页（第五个 Tab，排在「Root 权限」右侧）。
 *
 * 目前是**预留页**：功能待定。后续这里会承载 YOLO 推理 / 目标检测 / 瞄准输出相关的开关与参数。
 * 版式与其它页保持一致：标题 → 灰字说明 → 分节内容 →（后续）底部主按钮。
 */
@Composable
fun YoloAimScreen(
    // 预留：后续接入推理状态、设备/模型选择、灵敏度等
    statusText: String = "预留页 · 功能待定"
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
    ) {
        Text(
            text = "YOLO 自瞄",
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 12.dp)
        )

        Text(
            text = "预留页 —— 具体功能待定。后续这一页承载 YOLO 目标检测与瞄准输出相关的开关、参数与状态；" +
                "与既有功能（虚拟光标 / 端口转发 / 融合）互不干扰。",
            fontSize = 14.sp,
            color = Color.Gray,
            modifier = Modifier.padding(bottom = 12.dp)
        )

        Text(
            text = "状态：$statusText",
            fontSize = 15.sp,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        HorizontalDivider(modifier = Modifier.padding(vertical = 14.dp))

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .verticalScroll(rememberScrollState())
        ) {
            Text(
                text = "计划承载的内容（待定）",
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(bottom = 8.dp)
            )
            Text(
                text = "· 模型 / 推理后端选择（本地 NCNN / TFLite / 远程）\n" +
                    "· 检测参数：置信度、NMS、输入分辨率、帧率上限\n" +
                    "· 瞄准参数：目标选择策略、平滑、预测、触发方式\n" +
                    "· 采集方式：屏幕截图 / 板子回传帧（与 6532、6535 通道的关系待定）\n" +
                    "· 运行状态与性能面板（耗时、丢帧、目标数）",
                fontSize = 13.sp,
                color = Color.Gray,
                lineHeight = 21.sp
            )

            Spacer(modifier = Modifier.height(14.dp))

            Text(
                text = "设计约束（沿用本仓库既有结论）",
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(bottom = 8.dp)
            )
            Text(
                text = "· 板子 lwIP 只有 10 个 TCP PCB、6532 的 RX 环 4096B —— 新增通道必须复用现有连接或严格限流；\n" +
                    "· 若需要注入操作，优先走 0xFE（HID 鼠标键）/ 0xFC（core_input 调度），不要和触摸帧抢触点；\n" +
                    "· 任何新增的 root 常驻进程都要能被 stop 干净回收（参考 fusion 的 SIGTERM 处理）。",
                fontSize = 12.sp,
                fontFamily = FontFamily.Monospace,
                color = Color.Gray,
                lineHeight = 19.sp
            )

            Spacer(modifier = Modifier.height(14.dp))

            Text(
                text = "说明：这一页目前没有任何开关或后台服务，纯占位；确定功能后在这里逐项落地。",
                fontSize = 12.sp,
                color = Color.Gray
            )
        }
    }
}
