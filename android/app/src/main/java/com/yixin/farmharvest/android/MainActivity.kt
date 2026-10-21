package com.yixin.farmharvest.android

import android.app.AlarmManager
import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.app.NotificationManagerCompat
import androidx.core.view.WindowCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

class MainActivity : ComponentActivity() {
    internal val records = mutableStateListOf<CropRecord>()
    internal val presets = mutableStateListOf<CropPreset>()
    internal var selectedPresetId by mutableStateOf("")
    internal var minutesText by mutableStateOf("30")
    internal var noteText by mutableStateOf("")
    internal var lastUploadTimestamp by mutableLongStateOf(0L)
    private var hasLoadedOnce = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.getInsetsController(window, window.decorView)
            .isAppearanceLightNavigationBars = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1
        reload()
        setContent {
            FarmHarvestTheme {
                FarmHarvestApp(activity = this)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        if (hasLoadedOnce) reload()
    }

    internal fun reload() {
        val loadedRecords = FarmStore.loadRecords(this)
        val loadedPresets = FarmStore.presets(this)
        records.clear()
        records.addAll(loadedRecords)
        presets.clear()
        presets.addAll(loadedPresets)
        if (presets.none { it.id == selectedPresetId } && presets.isNotEmpty()) {
            selectedPresetId = presets.first().id
            minutesText = presets.first().minutes.toString()
        }
        lastUploadTimestamp = FarmStore.lastUploadTimestamp(this)
        ReminderScheduler.reschedule(this, loadedRecords)
        hasLoadedOnce = true
    }
}

private val farmGreen = Color(0xFF2E7D32)
private val pageColor = Color(0xFFF5F8F4)

@Composable
private fun FarmHarvestTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = farmGreen,
            onPrimary = Color.White,
            primaryContainer = Color(0xFFDCEBDD),
            onPrimaryContainer = farmGreen,
            secondary = Color(0xFF689F38),
            secondaryContainer = Color(0xFFDCEBDD),
            onSecondaryContainer = farmGreen,
            background = pageColor,
            surface = Color.White,
            surfaceVariant = Color(0xFFEEF4EE),
            onSurfaceVariant = Color(0xFF4F5D50),
            error = Color(0xFFB3261E),
        ),
        content = content,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FarmHarvestApp(activity: MainActivity) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    var selectedTab by rememberSaveable { mutableIntStateOf(0) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var showAddPreset by remember { mutableStateOf(false) }
    var editingRecord by remember { mutableStateOf<CropRecord?>(null) }
    var deletingRecord by remember { mutableStateOf<CropRecord?>(null) }
    var showClearConfirmation by remember { mutableStateOf(false) }
    var showReplaceConfirmation by remember { mutableStateOf(false) }
    var importMode by remember { mutableStateOf(ImportMode.MERGE) }
    var isImporting by remember { mutableStateOf(false) }
    var isUploading by remember { mutableStateOf(false) }

    val notificationPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { FarmStore.markNotificationPermissionAsked(activity) }
    LaunchedEffect(Unit) {
        while (true) {
            now = System.currentTimeMillis()
            delay(1_000)
        }
    }
    LaunchedEffect(Unit) {
        if (Build.VERSION.SDK_INT >= 33 &&
            activity.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED &&
            !FarmStore.wasNotificationPermissionAsked(activity)
        ) {
            notificationPermission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    val currentRecords = activity.records.toList()
    val clearableCount = currentRecords.count { it.harvests.isNotEmpty() &&
        it.harvests.all { cycle -> cycle.harvested || cycle.date <= now } }
    val message: (String) -> Unit = { text ->
        scope.launch { snackbar.showSnackbar(text) }
    }

    fun startImport(mode: ImportMode) {
        scope.launch {
            isImporting = true
            val before = activity.records.toList()
            try {
                val summary = withContext(Dispatchers.IO) {
                    val bytes = BackupApi.downloadBackup(FarmStore.SOURCE_BACKUP_URL)
                    FarmStore.importBackup(activity, bytes, mode)
                }
                activity.reload()
                val after = activity.records.toList()
                message(
                    if (mode == ImportMode.MERGE && before == after) {
                        "远程备份与本机记录一致（覆盖 ${summary.recordsOverwritten} 条）"
                    } else {
                        summary.text
                    },
                )
            } catch (error: Exception) {
                message("远程导入失败：${error.message ?: "请检查网络后重试"}")
            } finally {
                isImporting = false
            }
        }
    }

    fun startUpload() {
        scope.launch {
            isUploading = true
            try {
                val result = withContext(Dispatchers.IO) {
                    BackupApi.uploadBackup(FarmStore.exportBackup(activity))
                }
                val timestamp = System.currentTimeMillis()
                FarmStore.setLastUploadTimestamp(activity, timestamp)
                activity.lastUploadTimestamp = timestamp
                message(
                    if (result.fileName == FarmStore.SOURCE_BACKUP_FILE_NAME) {
                        "上传成功：${result.fileName}，可从固定地址导入。"
                    } else {
                        "上传成功，但服务器因同名自动保存为 ${result.fileName}；固定地址仍指向旧文件。接口不支持覆盖，请联系管理员提供固定文件更新方式。"
                    },
                )
            } catch (error: Exception) {
                message("上传失败：${error.message ?: "请检查网络后重试"}")
            } finally {
                isUploading = false
            }
        }
    }

    Scaffold(
        contentWindowInsets = WindowInsets(0.dp),
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        when (selectedTab) {
                            0 -> "新建事项"
                            1 -> "事项记录"
                            else -> "数据"
                        },
                        fontWeight = FontWeight.SemiBold,
                    )
                },
                actions = {
                    when (selectedTab) {
                        0 -> TextButton(onClick = { showAddPreset = true }) {
                            Text("+ 模板")
                        }
                        1 -> TextButton(
                            enabled = clearableCount > 0,
                            onClick = { showClearConfirmation = true },
                        ) {
                            Text("清理已结束")
                        }
                    }
                },
            )
        },
        bottomBar = {
            NavigationBar(containerColor = Color.White) {
                NavigationBarItem(
                    selected = selectedTab == 0,
                    onClick = { selectedTab = 0 },
                    icon = { Text("+", fontSize = 20.sp, fontWeight = FontWeight.Bold) },
                    label = { Text("新建事项") },
                )
                NavigationBarItem(
                    selected = selectedTab == 1,
                    onClick = { selectedTab = 1 },
                    icon = { Text("≡", fontSize = 20.sp, fontWeight = FontWeight.Bold) },
                    label = { Text("记录") },
                )
                NavigationBarItem(
                    selected = selectedTab == 2,
                    onClick = { selectedTab = 2 },
                    icon = { Text("↕", fontSize = 20.sp, fontWeight = FontWeight.Bold) },
                    label = { Text("数据") },
                )
            }
        },
        snackbarHost = { SnackbarHost(snackbar) },
        containerColor = pageColor,
    ) { insets ->
        when (selectedTab) {
            0 -> PlantForm(
                activity = activity,
                modifier = Modifier.padding(insets),
                onAddPreset = { showAddPreset = true },
                onMessage = message,
            )
            1 -> RecordsScreen(
                records = currentRecords,
                now = now,
                modifier = Modifier.padding(insets),
                onEdit = { editingRecord = it },
                onDelete = { deletingRecord = it },
                onToggleHarvest = { record, cycle ->
                    FarmStore.setHarvested(activity, record.id, cycle.id, !cycle.harvested)
                    activity.reload()
                },
                onRenew = {
                    FarmStore.renew(activity, it, now)
                    activity.reload()
                    message("已为「${it.name}」添加下一次提醒。")
                },
            )
            else -> DataScreen(
                activity = activity,
                importMode = importMode,
                onImportModeChange = { importMode = it },
                isImporting = isImporting,
                isUploading = isUploading,
                modifier = Modifier.padding(insets),
                onUpload = ::startUpload,
                onImport = {
                    if (importMode == ImportMode.REPLACE) {
                        showReplaceConfirmation = true
                    } else {
                        startImport(ImportMode.MERGE)
                    }
                },
            )
        }
    }

    if (showAddPreset) {
        AddPresetDialog(
            onDismiss = { showAddPreset = false },
            onCreate = { name, minutes ->
                val preset = FarmStore.addCustomCrop(activity, name, minutes)
                activity.reload()
                activity.selectedPresetId = preset.id
                activity.minutesText = preset.minutes.toString()
                showAddPreset = false
            },
        )
    }

    editingRecord?.let { record ->
        RecordEditDialog(
            record = record,
            now = now,
            onDismiss = { editingRecord = null },
            onSave = { updated ->
                FarmStore.updateRecord(activity, updated)
                activity.reload()
                editingRecord = null
                message("记录已保存。")
            },
        )
    }

    deletingRecord?.let { record ->
        val harvested = record.harvests.count { it.harvested }
        val next = record.harvests.filter { !it.harvested && it.date > now }
            .minOfOrNull { it.date }?.let(::formatDateTime) ?: "无"
        val details = if (record.harvests.size <= 1) {
            "提醒时间：${record.harvests.firstOrNull()?.date?.let(::formatDateTime) ?: "未设置"}。此操作不可撤销。"
        } else {
            "共 ${record.harvests.size} 次，已完成 $harvested 次。下次提醒：$next。此操作不可撤销。"
        }
        AlertDialog(
            onDismissRequest = { deletingRecord = null },
            title = { Text("删除「${record.name}」？") },
            text = { Text(details) },
            confirmButton = {
                TextButton(onClick = {
                    FarmStore.deleteRecord(activity, record.id)
                    activity.reload()
                    deletingRecord = null
                    message("记录已删除。")
                }) { Text("删除", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { deletingRecord = null }) { Text("取消") }
            },
        )
    }

    if (showClearConfirmation) {
        AlertDialog(
            onDismissRequest = { showClearConfirmation = false },
            title = { Text("清理已结束记录？") },
            text = {
                Text("仅清理所有提醒均已完成或已到期的记录；仍有未来提醒时间的记录会保留。")
            },
            confirmButton = {
                TextButton(onClick = {
                    FarmStore.clearFinishedRecords(activity, now)
                    activity.reload()
                    showClearConfirmation = false
                    message("已清理结束记录。")
                }) { Text("清除", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { showClearConfirmation = false }) { Text("取消") }
            },
        )
    }

    if (showReplaceConfirmation) {
        AlertDialog(
            onDismissRequest = { showReplaceConfirmation = false },
            title = { Text("用远程备份替换本机数据？") },
            text = { Text("当前提醒记录、自定义模板和内置模板隐藏状态将被远程备份覆盖。") },
            confirmButton = {
                TextButton(onClick = {
                    showReplaceConfirmation = false
                    startImport(ImportMode.REPLACE)
                }) { Text("下载并替换", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { showReplaceConfirmation = false }) { Text("取消") }
            },
        )
    }
}

@Composable
private fun PlantForm(
    activity: MainActivity,
    modifier: Modifier = Modifier,
    onAddPreset: () -> Unit,
    onMessage: (String) -> Unit,
) {
    val selected = activity.presets.firstOrNull { it.id == activity.selectedPresetId }
    val minutes = activity.minutesText.toIntOrNull()?.takeIf { it > 0 }
    val scroll = rememberScrollState()
    Column(
        modifier = modifier.fillMaxSize().imePadding().verticalScroll(scroll)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Card(colors = CardDefaults.cardColors(containerColor = Color.White)) {
            Column(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                SectionHeading("模板")
                if (activity.presets.isEmpty()) {
                    Text("还没有可选模板，请先添加。", color = Color.Gray)
                } else {
                    var expanded by remember { mutableStateOf(false) }
                    Box {
                        OutlinedButton(
                            onClick = { expanded = true },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(
                                Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                            ) {
                                Text(selected?.name ?: "选择模板")
                                Text("⌄")
                            }
                        }
                        androidx.compose.material3.DropdownMenu(
                            expanded = expanded,
                            onDismissRequest = { expanded = false },
                        ) {
                            activity.presets.forEach { preset ->
                                androidx.compose.material3.DropdownMenuItem(
                                    text = { Text(preset.name) },
                                    onClick = {
                                        activity.selectedPresetId = preset.id
                                        activity.minutesText = preset.minutes.toString()
                                        expanded = false
                                    },
                                )
                            }
                        }
                    }
                }
                TextButton(onClick = onAddPreset, modifier = Modifier.align(Alignment.End)) {
                    Text("+ 添加自定义模板")
                }
            }
        }

        Card(colors = CardDefaults.cardColors(containerColor = Color.White)) {
            Column(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                SectionHeading("提醒间隔")
                OutlinedTextField(
                    value = activity.minutesText,
                    onValueChange = { activity.minutesText = it.filter(Char::isDigit).take(8) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("分钟") },
                    suffix = { Text("分钟", color = Color.Gray) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                )
                if (minutes != null) {
                    Text(
                        "预计提醒：${formatDateTime(System.currentTimeMillis() + minutes * 60_000L)}",
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.Gray,
                    )
                } else {
                    Text("请输入大于 0 的分钟数", color = Color(0xFFB26A00))
                }
            }
        }

        Card(colors = CardDefaults.cardColors(containerColor = Color.White)) {
            Column(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                SectionHeading("备注（可选）")
                OutlinedTextField(
                    value = activity.noteText,
                    onValueChange = { activity.noteText = it },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text("例如：会议材料") },
                    minLines = 2,
                    maxLines = 4,
                )
            }
        }

        Button(
            onClick = {
                val preset = selected ?: return@Button
                val parsed = minutes ?: return@Button
                val before = activity.records.size
                FarmStore.addRecord(activity, preset, parsed, activity.noteText)
                activity.noteText = ""
                activity.reload()
                onMessage(
                    if (activity.records.size > before) {
                        "已添加「${preset.name}」，事项提醒已安排。"
                    } else {
                        "保存失败，请检查设备存储空间后重试。"
                    },
                )
            },
            enabled = selected != null && minutes != null,
            modifier = Modifier.fillMaxWidth().height(52.dp),
        ) {
            Text("添加提醒", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.height(10.dp))
    }
}

@Composable
private fun RecordsScreen(
    records: List<CropRecord>,
    now: Long,
    modifier: Modifier = Modifier,
    onEdit: (CropRecord) -> Unit,
    onDelete: (CropRecord) -> Unit,
    onToggleHarvest: (CropRecord, HarvestCycle) -> Unit,
    onRenew: (CropRecord) -> Unit,
) {
    val readyCount = records.count { record ->
        record.harvests.isNotEmpty() &&
            record.harvests.all { it.harvested || it.date <= now }
    }
    LazyColumn(
        modifier = modifier.fillMaxSize().padding(horizontal = 14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            Row(
                Modifier.fillMaxWidth().padding(top = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                StatCard("待提醒", records.size - readyCount, Color(0xFFEF8E2F), Modifier.weight(1f))
                StatCard("已到期", readyCount, farmGreen, Modifier.weight(1f))
                StatCard("总计", records.size, Color(0xFF4C77B8), Modifier.weight(1f))
            }
        }
        item {
            Text(
                "提醒记录（${records.size}）",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(top = 4.dp, bottom = 2.dp),
            )
        }
        if (records.isEmpty()) {
            item {
                Card(colors = CardDefaults.cardColors(containerColor = Color.White)) {
                    Column(
                        Modifier.fillMaxWidth().padding(26.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text("◷", fontSize = 30.sp, color = farmGreen)
                        Text("还没有提醒记录", fontWeight = FontWeight.SemiBold)
                        Text(
                            "到「新建事项」页面添加一条记录。",
                            color = Color.Gray,
                            textAlign = TextAlign.Center,
                        )
                    }
                }
            }
        } else {
            itemsIndexed(records, key = { _, record -> record.id }) { _, record ->
                RecordCard(
                    record = record,
                    now = now,
                    onEdit = { onEdit(record) },
                    onDelete = { onDelete(record) },
                    onToggleHarvest = { onToggleHarvest(record, it) },
                    onRenew = { onRenew(record) },
                )
            }
        }
        item { Spacer(Modifier.height(10.dp)) }
    }
}

@Composable
private fun StatCard(title: String, value: Int, tint: Color, modifier: Modifier = Modifier) {
    Card(
        modifier = modifier,
        colors = CardDefaults.cardColors(containerColor = tint.copy(alpha = 0.10f)),
        shape = RoundedCornerShape(14.dp),
    ) {
        Column(
            Modifier.fillMaxWidth().padding(vertical = 10.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(value.toString(), color = tint, fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Text(title, color = Color.Gray, style = MaterialTheme.typography.labelSmall)
        }
    }
}

@Composable
private fun RecordCard(
    record: CropRecord,
    now: Long,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onToggleHarvest: (HarvestCycle) -> Unit,
    onRenew: () -> Unit,
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = Color.White),
        shape = RoundedCornerShape(18.dp),
    ) {
        Column(
            Modifier.fillMaxWidth().padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier.size(38.dp).background(parseHex(record.colorHex), CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        record.name.take(1),
                        color = Color.White,
                        fontWeight = FontWeight.Bold,
                    )
                }
                Spacer(Modifier.width(10.dp))
                Text(
                    record.name,
                    modifier = Modifier.weight(1f),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                TextButton(onClick = onEdit) { Text("编辑") }
                TextButton(onClick = onRenew) { Text("再次提醒") }
            }
            record.note?.takeIf(String::isNotBlank)?.let { note ->
                Surface(
                    color = Color(0xFFF4F7F3),
                    shape = RoundedCornerShape(10.dp),
                ) {
                    Text(note, Modifier.fillMaxWidth().padding(10.dp), style = MaterialTheme.typography.bodySmall)
                }
            }
            record.harvests.sortedBy { it.date }.forEachIndexed { index, cycle ->
                Row(
                    Modifier.fillMaxWidth().padding(start = 42.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        val urgencyColor = when {
                            cycle.harvested -> Color(0xFF5A8B63)
                            cycle.date <= now -> Color(0xFFEF8E2F)
                            cycle.date - now <= 10 * 60_000L -> Color(0xFFD32F2F)
                            cycle.date - now <= 20 * 60_000L -> Color(0xFFEF8E2F)
                            cycle.date - now <= 30 * 60_000L -> Color(0xFF9A7813)
                            else -> Color.DarkGray
                        }
                        Text(
                            "第 ${index + 1} 次 · ${formatDateTime(cycle.date)}",
                            color = urgencyColor,
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = if (cycle.date - now <= 20 * 60_000L && !cycle.harvested) {
                                FontWeight.SemiBold
                            } else {
                                FontWeight.Medium
                            },
                        )
                        Text(
                            when {
                                cycle.harvested -> "已完成"
                                cycle.date <= now -> "已到期"
                                else -> "还剩 ${remainText(cycle.date, now)}"
                            },
                            color = urgencyColor,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                    TextButton(onClick = { onToggleHarvest(cycle) }) {
                        Text(if (cycle.harvested) "撤销" else "已完成")
                    }
                }
            }
            HorizontalDivider(color = Color(0xFFF0F0F0))
            TextButton(
                onClick = onDelete,
                modifier = Modifier.align(Alignment.End),
            ) {
                Text("删除记录", color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

@Composable
private fun DataScreen(
    activity: MainActivity,
    importMode: ImportMode,
    onImportModeChange: (ImportMode) -> Unit,
    isImporting: Boolean,
    isUploading: Boolean,
    modifier: Modifier = Modifier,
    onUpload: () -> Unit,
    onImport: () -> Unit,
) {
    val context = LocalContext.current
    Column(
        modifier.fillMaxSize().verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        val notificationsEnabled = NotificationManagerCompat.from(context).areNotificationsEnabled()
        val exactAlarmsEnabled = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            (context.getSystemService(AlarmManager::class.java)?.canScheduleExactAlarms() == true)
        Card(colors = CardDefaults.cardColors(containerColor = Color.White)) {
            Column(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                SectionHeading("提醒权限")
                Text(
                    if (notificationsEnabled) "通知：已允许" else "通知：未允许，提醒不会显示",
                    color = if (notificationsEnabled) farmGreen else MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                )
                if (!notificationsEnabled) {
                    OutlinedButton(
                        onClick = {
                            context.startActivity(
                                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                    .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName),
                            )
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("打开通知设置") }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    Text(
                        if (exactAlarmsEnabled) {
                            "准时提醒：已允许精确闹钟"
                        } else {
                            "准时提醒：当前使用省电调度，系统可能延迟通知。"
                        },
                        color = if (exactAlarmsEnabled) farmGreen else Color(0xFFB26A00),
                        style = MaterialTheme.typography.bodySmall,
                    )
                    if (!exactAlarmsEnabled) {
                        OutlinedButton(
                            onClick = {
                                context.startActivity(
                                    Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                                        .setData(Uri.parse("package:${context.packageName}")),
                                )
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) { Text("开启精确提醒") }
                    }
                }
            }
        }

        Card(colors = CardDefaults.cardColors(containerColor = Color.White)) {
            Column(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                SectionHeading("上传备份到共享目录")
                Text(
                    "上传文件名：${FarmStore.SOURCE_BACKUP_FILE_NAME}。固定导入地址：${FarmStore.SOURCE_BACKUP_URL}。请仅在可信局域网内使用。",
                    color = Color.Gray,
                    style = MaterialTheme.typography.bodySmall,
                )
                Text(
                    "接口不覆盖已有文件；若同名文件存在，服务器会追加序号，固定地址仍指向原文件。",
                    color = Color.Gray,
                    style = MaterialTheme.typography.bodySmall,
                )
                Button(
                    onClick = onUpload,
                    enabled = !isUploading,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    if (isUploading) {
                        LinearProgressIndicator(Modifier.fillMaxWidth(0.65f))
                        Spacer(Modifier.width(8.dp))
                        Text("正在上传备份…")
                    } else {
                        Text("↑  上传当前备份")
                    }
                }
                val uploadTime = if (activity.lastUploadTimestamp > 0) {
                    formatUploadTime(activity.lastUploadTimestamp)
                } else {
                    "暂无"
                }
                Text("最近上传：$uploadTime", color = Color.Gray, style = MaterialTheme.typography.bodySmall)
            }
        }

        Card(colors = CardDefaults.cardColors(containerColor = Color.White)) {
            Column(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(9.dp),
            ) {
                SectionHeading("远程备份地址")
                Text(
                    FarmStore.SOURCE_BACKUP_URL,
                    color = Color(0xFF4F5D50),
                    style = MaterialTheme.typography.bodySmall,
                )
                Text(
                    "手机和电脑都可从共享目录下载地址或 HTTPS 地址导入。",
                    color = Color.Gray,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }

        Card(colors = CardDefaults.cardColors(containerColor = Color.White)) {
            Column(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                SectionHeading("导入方式")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(
                        selected = importMode == ImportMode.MERGE,
                        onClick = { onImportModeChange(ImportMode.MERGE) },
                        label = { Text("合并") },
                    )
                    FilterChip(
                        selected = importMode == ImportMode.REPLACE,
                        onClick = { onImportModeChange(ImportMode.REPLACE) },
                        label = { Text("替换") },
                    )
                }
                Text(
                    if (importMode == ImportMode.MERGE) {
                        "同 ID 的记录和模板会更新，本机没有的项目会追加；本机独有项目保留。"
                    } else {
                        "完全采用远程备份，会覆盖本机记录、自定义模板和隐藏的内置模板。"
                    },
                    color = Color.Gray,
                    style = MaterialTheme.typography.bodySmall,
                )
                Button(
                    onClick = onImport,
                    enabled = !isImporting,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    if (isImporting) {
                        LinearProgressIndicator(Modifier.fillMaxWidth(0.60f))
                        Spacer(Modifier.width(8.dp))
                        Text("正在下载并导入…")
                    } else {
                        Text("↓  获取并导入")
                    }
                }
            }
        }

        Card(colors = CardDefaults.cardColors(containerColor = Color.White)) {
            Text(
                "上传会将当前备份保存为一个新文件，不会覆盖已有文件；手机上的修改不会自动同步。",
                Modifier.fillMaxWidth().padding(16.dp),
                color = Color.Gray,
                style = MaterialTheme.typography.bodySmall,
            )
        }
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun AddPresetDialog(
    onDismiss: () -> Unit,
    onCreate: (String, Int) -> Unit,
) {
    var name by remember { mutableStateOf("") }
    var minutes by remember { mutableStateOf("30") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("添加模板") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("名称") },
                    singleLine = true,
                )
                OutlinedTextField(
                    value = minutes,
                    onValueChange = { minutes = it.filter(Char::isDigit).take(8) },
                    label = { Text("提醒间隔（分钟）") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = name.trim().isNotEmpty(),
                onClick = {
                    val parsed = minutes.toIntOrNull()
                    if (name.trim().isNotEmpty() && parsed != null && parsed > 0) {
                        onCreate(name.trim(), parsed)
                    }
                },
            ) { Text("添加") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

@Composable
private fun RecordEditDialog(
    record: CropRecord,
    now: Long,
    onDismiss: () -> Unit,
    onSave: (CropRecord) -> Unit,
) {
    val context = LocalContext.current
    var name by remember(record.id) { mutableStateOf(record.name) }
    var note by remember(record.id) { mutableStateOf(record.note.orEmpty()) }
    var cycles by remember(record.id) {
        mutableStateOf(record.harvests.sortedBy { it.date })
    }
    var newCycleMode by remember(record.id) { mutableStateOf(false) }
    var newHours by remember(record.id) { mutableStateOf("1") }
    var newMinutes by remember(record.id) { mutableStateOf("0") }
    var newDate by remember(record.id) {
        mutableLongStateOf(now + record.minutes.coerceAtLeast(1) * 60_000L)
    }
    val adjustmentHours = remember(record.id) { mutableStateMapOf<String, String>() }
    val adjustmentMinutes = remember(record.id) { mutableStateMapOf<String, String>() }
    val editedAdjustments = remember(record.id) { mutableStateListOf<String>() }
    val expandedAdjustments = remember(record.id) { mutableStateListOf<String>() }
    var deletingCycle by remember(record.id) { mutableStateOf<HarvestCycle?>(null) }

    fun adjustmentDuration(id: String): Long? {
        val hours = adjustmentHours[id]?.toLongOrNull() ?: if (id !in adjustmentHours) 1L else return null
        val minutes = adjustmentMinutes[id]?.toLongOrNull() ?: if (id !in adjustmentMinutes) 0L else return null
        if (hours < 0 || minutes < 0) return null
        return hours * 60 + minutes
    }

    fun changeCycle(updated: HarvestCycle) {
        cycles = cycles.map { if (it.id == updated.id) updated else it }.sortedBy { it.date }
    }

    val newDuration = newHours.toLongOrNull()?.let { hours ->
        newMinutes.toLongOrNull()?.let { minutes ->
            if (hours >= 0 && minutes >= 0) hours * 60 + minutes else null
        }
    }
    val newPreview = if (newCycleMode) newDate else newDuration?.let { now + it * 60_000L }
    val invalidAdjustments = editedAdjustments.any { (adjustmentDuration(it) ?: 0L) <= 0 }
    val harvestedCount = cycles.count { it.harvested }
    val nextCycle = cycles.filter { !it.harvested && it.date > now }.minOfOrNull { it.date }
    val summary = buildString {
        append("共 ${cycles.size} 次 · 已完成 $harvestedCount")
        if (nextCycle != null) append(" · 下次 ${formatDateTime(nextCycle)}")
        else if (harvestedCount < cycles.size) append(" · 有 ${cycles.size - harvestedCount} 次待处理")
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            modifier = Modifier.fillMaxWidth(0.96f).fillMaxHeight(0.92f),
            shape = RoundedCornerShape(24.dp),
            color = pageColor,
        ) {
            Column(Modifier.fillMaxSize()) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("编辑记录", modifier = Modifier.weight(1f), fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                    TextButton(onClick = onDismiss) { Text("取消") }
                    TextButton(
                        enabled = cycles.isNotEmpty() && !invalidAdjustments,
                        onClick = {
                            val adjusted = cycles.map { cycle ->
                                if (cycle.id !in editedAdjustments) cycle
                                else cycle.copy(date = now + (adjustmentDuration(cycle.id) ?: 0L) * 60_000L)
                            }.sortedBy { it.date }
                            val trimmedName = name.trim().ifEmpty { record.name }
                            val trimmedNote = note.trim().ifEmpty { null }
                            val firstDate = adjusted.firstOrNull()?.date ?: return@TextButton
                            onSave(
                                record.copy(
                                    name = trimmedName,
                                    note = trimmedNote,
                                    minutes = ((firstDate - record.plantedAt) / 60_000L).coerceAtLeast(0)
                                        .coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                                    harvests = adjusted,
                                ),
                            )
                        },
                    ) { Text("保存") }
                }
                HorizontalDivider()

                LazyColumn(
                    modifier = Modifier.weight(1f).imePadding(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(
                        start = 14.dp,
                        end = 14.dp,
                        top = 12.dp,
                        bottom = 18.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    item {
                        Card(colors = CardDefaults.cardColors(containerColor = Color.White)) {
                            Column(
                                Modifier.fillMaxWidth().padding(14.dp),
                                verticalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                SectionHeading("记录信息")
                                OutlinedTextField(
                                    value = name,
                                    onValueChange = { name = it },
                                    modifier = Modifier.fillMaxWidth(),
                                    label = { Text("事项名称") },
                                    singleLine = true,
                                )
                                OutlinedTextField(
                                    value = note,
                                    onValueChange = { note = it },
                                    modifier = Modifier.fillMaxWidth(),
                                    label = { Text("备注说明") },
                                    minLines = 2,
                                    maxLines = 4,
                                )
                            }
                        }
                    }
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            SectionHeading("提醒时间（每次提醒可单独编辑）")
                            if (cycles.isEmpty()) {
                                Text(
                                    "至少保留一个提醒时间，或先添加一次提醒再保存。",
                                    color = Color(0xFFB26A00),
                                    style = MaterialTheme.typography.bodySmall,
                                )
                            }
                            Text(summary, color = Color.Gray, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    itemsIndexed(cycles, key = { _, cycle -> cycle.id }) { index, cycle ->
                        Card(colors = CardDefaults.cardColors(containerColor = Color.White)) {
                            Column(
                                Modifier.fillMaxWidth().padding(12.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        "第 ${index + 1} 次提醒",
                                        modifier = Modifier.weight(1f),
                                        fontWeight = FontWeight.SemiBold,
                                    )
                                    TextButton(onClick = { pickDateTime(context, cycle.date) { picked ->
                                        changeCycle(cycle.copy(date = picked))
                                    } }) {
                                        Text(formatDateTime(cycle.date))
                                    }
                                }
                                TextButton(
                                    onClick = {
                                        if (cycle.id in expandedAdjustments) {
                                            expandedAdjustments.remove(cycle.id)
                                        } else {
                                            expandedAdjustments.add(cycle.id)
                                            adjustmentHours.putIfAbsent(cycle.id, "1")
                                            adjustmentMinutes.putIfAbsent(cycle.id, "0")
                                        }
                                    },
                                ) {
                                    Text(if (cycle.id in expandedAdjustments) "⌄ 从现在起调整" else "› 从现在起调整")
                                }
                                if (cycle.id in expandedAdjustments) {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                                    ) {
                                        OutlinedTextField(
                                            value = adjustmentHours[cycle.id] ?: "1",
                                            onValueChange = {
                                                adjustmentHours[cycle.id] = it.filter(Char::isDigit).take(6)
                                                if (cycle.id !in editedAdjustments) editedAdjustments.add(cycle.id)
                                            },
                                            modifier = Modifier.weight(1f),
                                            label = { Text("小时") },
                                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                            singleLine = true,
                                        )
                                        OutlinedTextField(
                                            value = adjustmentMinutes[cycle.id] ?: "0",
                                            onValueChange = {
                                                adjustmentMinutes[cycle.id] = it.filter(Char::isDigit).take(6)
                                                if (cycle.id !in editedAdjustments) editedAdjustments.add(cycle.id)
                                            },
                                            modifier = Modifier.weight(1f),
                                            label = { Text("分钟") },
                                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                            singleLine = true,
                                        )
                                    }
                                    adjustmentDuration(cycle.id)?.let { duration ->
                                        Text(
                                            "从现在起 → ${formatDateTime(now + duration * 60_000L)}",
                                            color = Color.Gray,
                                            style = MaterialTheme.typography.bodySmall,
                                        )
                                    }
                                    TextButton(
                                        enabled = (adjustmentDuration(cycle.id) ?: 0L) > 0,
                                        onClick = {
                                            val duration = adjustmentDuration(cycle.id) ?: return@TextButton
                                            changeCycle(cycle.copy(date = now + duration * 60_000L))
                                            editedAdjustments.remove(cycle.id)
                                        },
                                    ) { Text("按此时间设置") }
                                }
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Switch(
                                        checked = cycle.harvested,
                                        onCheckedChange = { changeCycle(cycle.copy(harvested = it)) },
                                    )
                                    Text("已完成", modifier = Modifier.weight(1f))
                                    Text(
                                        when {
                                            cycle.harvested -> "已完成"
                                            cycle.date <= now -> "已到期"
                                            else -> "还剩 ${remainText(cycle.date, now)}"
                                        },
                                        color = if (cycle.harvested) farmGreen else Color.Gray,
                                        style = MaterialTheme.typography.bodySmall,
                                    )
                                    TextButton(onClick = { deletingCycle = cycle }) {
                                        Text("删除", color = MaterialTheme.colorScheme.error)
                                    }
                                }
                            }
                        }
                    }
                    item {
                        Card(colors = CardDefaults.cardColors(containerColor = Color.White)) {
                            Column(
                                Modifier.fillMaxWidth().padding(14.dp),
                                verticalArrangement = Arrangement.spacedBy(9.dp),
                            ) {
                                SectionHeading("添加下一次提醒")
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    FilterChip(
                                        selected = !newCycleMode,
                                        onClick = { newCycleMode = false },
                                        label = { Text("从现在起") },
                                    )
                                    FilterChip(
                                        selected = newCycleMode,
                                        onClick = { newCycleMode = true },
                                        label = { Text("指定时间") },
                                    )
                                }
                                if (newCycleMode) {
                                    OutlinedButton(
                                        onClick = { pickDateTime(context, newDate) { newDate = it } },
                                        modifier = Modifier.fillMaxWidth(),
                                    ) { Text("提醒时间：${formatDateTime(newDate)}") }
                                } else {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                                    ) {
                                        OutlinedTextField(
                                            value = newHours,
                                            onValueChange = { newHours = it.filter(Char::isDigit).take(6) },
                                            modifier = Modifier.weight(1f),
                                            label = { Text("小时") },
                                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                            singleLine = true,
                                        )
                                        OutlinedTextField(
                                            value = newMinutes,
                                            onValueChange = { newMinutes = it.filter(Char::isDigit).take(6) },
                                            modifier = Modifier.weight(1f),
                                            label = { Text("分钟") },
                                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                            singleLine = true,
                                        )
                                    }
                                }
                                newPreview?.let {
                                    Text(
                                        if (newCycleMode) "预计提醒：${formatDateTime(it)}"
                                        else "从现在起 · ${formatDateTime(it)}",
                                        color = Color.Gray,
                                        style = MaterialTheme.typography.bodySmall,
                                    )
                                }
                                Button(
                                    enabled = newPreview != null && newPreview!! > now,
                                    onClick = {
                                        val preview = newPreview ?: return@Button
                                        cycles = (cycles + HarvestCycle(date = preview)).sortedBy { it.date }
                                        newDate = preview
                                    },
                                    modifier = Modifier.fillMaxWidth(),
                                ) { Text("+ 添加这一次提醒") }
                            }
                        }
                    }
                }
            }
        }
    }

    deletingCycle?.let { cycle ->
        val remaining = cycles.size - 1
        AlertDialog(
            onDismissRequest = { deletingCycle = null },
            title = { Text("删除这一次提醒？") },
            text = {
                Text(
                    if (remaining == 0) {
                        "提醒时间 ${formatDateTime(cycle.date)}。这是唯一一次提醒，删除后需要重新添加才能保存。"
                    } else {
                        "提醒时间 ${formatDateTime(cycle.date)}。删除后还剩 $remaining 次。"
                    },
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    cycles = cycles.filterNot { it.id == cycle.id }
                    deletingCycle = null
                }) { Text("删除", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { deletingCycle = null }) { Text("取消") } },
        )
    }
}

@Composable
private fun SectionHeading(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
}

private fun pickDateTime(context: android.content.Context, initial: Long, onPicked: (Long) -> Unit) {
    val calendar = Calendar.getInstance().apply { timeInMillis = initial }
    DatePickerDialog(
        context,
        { _, year, month, day ->
            val selected = Calendar.getInstance().apply {
                timeInMillis = initial
                set(Calendar.YEAR, year)
                set(Calendar.MONTH, month)
                set(Calendar.DAY_OF_MONTH, day)
            }
            TimePickerDialog(
                context,
                { _, hour, minute ->
                    selected.set(Calendar.HOUR_OF_DAY, hour)
                    selected.set(Calendar.MINUTE, minute)
                    selected.set(Calendar.SECOND, 0)
                    selected.set(Calendar.MILLISECOND, 0)
                    onPicked(selected.timeInMillis)
                },
                calendar.get(Calendar.HOUR_OF_DAY),
                calendar.get(Calendar.MINUTE),
                true,
            ).show()
        },
        calendar.get(Calendar.YEAR),
        calendar.get(Calendar.MONTH),
        calendar.get(Calendar.DAY_OF_MONTH),
    ).show()
}

private fun formatDateTime(timestamp: Long): String =
    SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()).format(Date(timestamp))

private fun formatUploadTime(timestamp: Long): String =
    SimpleDateFormat("yyyy/M/d HH:mm", Locale.getDefault()).format(Date(timestamp))

private fun remainText(target: Long, now: Long): String {
    val totalSeconds = ((target - now) / 1_000L).coerceAtLeast(0)
    val hours = totalSeconds / 3_600
    val minutes = (totalSeconds % 3_600) / 60
    val seconds = totalSeconds % 60
    return if (hours > 0) {
        "%d:%02d:%02d".format(Locale.getDefault(), hours, minutes, seconds)
    } else {
        "%02d:%02d".format(Locale.getDefault(), minutes, seconds)
    }
}

private fun parseHex(value: String): Color = runCatching {
    val normalized = value.trim().removePrefix("#")
    Color(android.graphics.Color.parseColor("#$normalized"))
}.getOrDefault(farmGreen)
