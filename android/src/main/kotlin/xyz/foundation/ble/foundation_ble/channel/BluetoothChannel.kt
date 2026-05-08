package xyz.foundation.ble.foundation_ble.channel

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.core.app.ActivityCompat
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.util.UUID
import xyz.foundation.ble.foundation_ble.connection.BleConnection
import xyz.foundation.ble.foundation_ble.connection.BleConnectionCallback
import xyz.foundation.ble.foundation_ble.connection.gatt.GattBleConnection
import xyz.foundation.ble.foundation_ble.model.BluetoothConnectionEventType
import xyz.foundation.ble.foundation_ble.transport.SessionChannelNames

class BluetoothChannel(
    private val context: Context,
    activity: Activity,
    activityBinding: ActivityPluginBinding,
    private val binaryMessenger: BinaryMessenger
) : MethodChannel.MethodCallHandler,
    BleConnectionCallback,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {

    companion object {
        private const val TAG = "BluetoothChannel"
        private const val REQUEST_BLE_PERMISSIONS_CODE = 9200
        private const val ENABLE_BLUETOOTH_REQUEST_CODE = 9201
    }

    private data class TrackedBleConnection(
        val connection: BleConnection
    )

    private val channelNames = SessionChannelNames.defaultNames()

    private val methodChannel: MethodChannel =
        MethodChannel(binaryMessenger, channelNames.methodChannelName)
    private val scanEventChannel: EventChannel =
        EventChannel(binaryMessenger, channelNames.scanStreamName)
    private var scanEventSink: EventChannel.EventSink? = null

    private val bluetoothManager: BluetoothManager =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter
    private var bluetoothLeScanner: BluetoothLeScanner? = bluetoothAdapter?.bluetoothLeScanner
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null

    private var knownDeviceMacs: MutableSet<String> = mutableSetOf()
    private val devices: MutableMap<String, TrackedBleConnection> = mutableMapOf()

    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(Dispatchers.Main)

    private var bondingReceiver: BroadcastReceiver? = null
    private var isReceiverRegistered = false
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingEnableResult: MethodChannel.Result? = null
    private var activeScanTargetMacId: String? = null
    private var activeScanServiceUuid: UUID? = null
    private var hasAttachedActivity = false
    private val stopScanRunnable: Runnable = Runnable {
        stopScanInternal(sendEvent = true)
    }

    init {
        methodChannel.setMethodCallHandler(this)
        scanEventChannel.setStreamHandler(ScanStreamHandler())
        attachToActivity(activity, activityBinding)
        setupBondingReceiver()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestBlePermissions" -> requestBlePermissions(result)
            "getBleAdapterState" -> result.success(bluetoothAdapter?.isEnabled == true)
            "enableBluetooth" -> enableBluetooth(result)
            "deviceName" -> getDeviceName(result)
            "startScan" -> startDeviceScan(call, result)
            "stopScan" -> stopDeviceScan(result)
            "pair" -> pairWithDevice(call, result)
            "apiLevel" -> result.success(Build.VERSION.SDK_INT)
            "prepareDevice" -> prepareDevice(call, result)
            "reconnect" -> reconnect(call, result)
            "getConnectedDevices" -> getConnectedDevices(call, result)
            "removeDevice" -> removeDevice(call, result)
            else -> result.notImplemented()
        }
    }

    override fun onDeviceDisconnected(device: BleConnection) {
        Log.d(TAG, "Device disconnected: ${device.deviceId}")
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != ENABLE_BLUETOOTH_REQUEST_CODE) {
            return false
        }

        pendingEnableResult?.success(resultCode == Activity.RESULT_OK)
        pendingEnableResult = null
        return true
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != REQUEST_BLE_PERMISSIONS_CODE) {
            return false
        }

        val granted = grantResults.isNotEmpty() &&
                grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
        return true
    }

    fun attachToActivity(activity: Activity, activityBinding: ActivityPluginBinding) {
        if (hasAttachedActivity &&
            this.activity === activity &&
            this.activityBinding === activityBinding
        ) {
            return
        }

        detachActivity(cancelPendingResults = false)
        this.activity = activity
        this.activityBinding = activityBinding
        activityBinding.addActivityResultListener(this)
        activityBinding.addRequestPermissionsResultListener(this)
        hasAttachedActivity = true
    }

    fun detachFromActivityForConfigChanges() {
        detachActivity(cancelPendingResults = true)
    }

    private fun requestBlePermissions(result: MethodChannel.Result) {
        if (hasBlePermissions()) {
            result.success(true)
            return
        }

        val hostActivity = activity
        if (hostActivity == null) {
            result.error("NO_ACTIVITY", "Bluetooth activity not attached", null)
            return
        }

        val permissions = requiredBlePermissions()
        if (permissions.isEmpty()) {
            result.success(true)
            return
        }

        if (pendingPermissionResult != null) {
            result.error(
                "PERMISSION_REQUEST_IN_PROGRESS",
                "Bluetooth permission request already in progress",
                null
            )
            return
        }

        pendingPermissionResult = result
        ActivityCompat.requestPermissions(hostActivity, permissions, REQUEST_BLE_PERMISSIONS_CODE)
    }

    private fun enableBluetooth(result: MethodChannel.Result) {
        if (bluetoothAdapter?.isEnabled == true) {
            result.success(true)
            return
        }

        val hostActivity = activity
        if (hostActivity == null) {
            result.error("NO_ACTIVITY", "Bluetooth activity not attached", null)
            return
        }

        if (!hasBluetoothConnectPermission()) {
            result.error("PERMISSION_ERROR", "Bluetooth connect permission not granted", null)
            return
        }

        if (ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_CONNECT
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            result.error("PERMISSION_ERROR", "Bluetooth connect permission not granted", null)
            return
        }
        pendingEnableResult = result
        hostActivity.startActivityForResult(
            Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),
            ENABLE_BLUETOOTH_REQUEST_CODE
        )
    }

    @SuppressLint("MissingPermission")
    private fun getDeviceName(result: MethodChannel.Result) {
        if (!checkBluetoothPermissions()) {
            result.error("PERMISSION_ERROR", "Bluetooth permissions not granted", null)
            return
        }

        result.success(bluetoothAdapter?.name ?: "Foundation")
    }

    @SuppressLint("MissingPermission")
    private fun getConnectedDevices(call: MethodCall, result: MethodChannel.Result) {
        if (!checkBluetoothPermissions()) {
            result.error("PERMISSION_ERROR", "Bluetooth permissions not granted", null)
            return
        }

        if (bluetoothAdapter?.isEnabled != true) {
            result.success(emptyList<Map<String, Any?>>())
            return
        }

        val accessories = buildGattConnectedDevices()

        result.success(accessories)
    }

    private fun removeDevice(call: MethodCall, result: MethodChannel.Result) {
        val deviceId = call.argument<String>("deviceId")
        if (deviceId.isNullOrBlank()) {
            result.error("INVALID_DEVICE_ID", "Device ID is required", null)
            return
        }

        val trackedDevice = devices.remove(deviceId)
        trackedDevice?.connection?.cleanup()
        val removed = knownDeviceMacs.remove(deviceId) || trackedDevice != null
        result.success(removed)
    }

    @SuppressLint("MissingPermission")
    private fun pairWithDevice(call: MethodCall, result: MethodChannel.Result) {
        if (!checkBluetoothPermissions()) {
            result.error("PERMISSION_ERROR", "Bluetooth permissions not granted", null)
            return
        }

        val deviceId = call.argument<String>("deviceId")
        if (!deviceId.isNullOrBlank()) {
            knownDeviceMacs.add(deviceId)
            getOrCreateDevice(deviceId)
        }
        startDeviceScan(call, result)
    }

    private fun getOrCreateDevice(deviceId: String): BleConnection {
        val existingDevice = devices[deviceId]
        if (existingDevice != null && !existingDevice.connection.isCleanedUp) {
            return existingDevice.connection
        }

        existingDevice?.connection?.cleanup()

        val connection = GattBleConnection(
            deviceId = deviceId,
            context = context,
            bluetoothManager = bluetoothManager,
            binaryMessenger = binaryMessenger,
            callback = this,
            channelNames = channelNames,
            scope = scope
        )
        devices[deviceId] = TrackedBleConnection(connection = connection)
        return connection
    }

    private fun prepareDevice(call: MethodCall, result: MethodChannel.Result) {
        val deviceId = call.argument<String>("deviceId")
        if (deviceId.isNullOrBlank()) {
            result.error("INVALID_DEVICE_ID", "Device ID is required", null)
            return
        }

        try {
            getOrCreateDevice(deviceId)
            result.success(true)
        } catch (error: Exception) {
            result.error("PREPARE_ERROR", "Failed to prepare device: ${error.message}", null)
        }
    }

    @SuppressLint("MissingPermission")
    private fun reconnect(call: MethodCall, result: MethodChannel.Result) {
        if (!checkBluetoothPermissions()) {
            result.error("PERMISSION_ERROR", "Bluetooth permissions not granted", null)
            return
        }

        val deviceId = call.argument<String>("deviceId")
        if (deviceId.isNullOrBlank()) {
            result.error("INVALID_DEVICE_ID", "Device ID is required", null)
            return
        }

        try {
            val adapter = bluetoothManager.adapter
            if (adapter == null) {
                result.error("NO_ADAPTER", "Bluetooth adapter not available", null)
                return
            }

            val bleConnection = getOrCreateDevice(deviceId)
            val remoteDevice = adapter.getRemoteDevice(deviceId)
            bleConnection.connect(remoteDevice)
            result.success(true)
        } catch (error: Exception) {
            result.error("RECONNECT_ERROR", "Failed to reconnect: ${error.message}", null)
        }
    }

    @SuppressLint("MissingPermission")
    private fun startDeviceScan(call: MethodCall, result: MethodChannel.Result) {
        if (!checkBluetoothPermissions()) {
            result.error("PERMISSION_ERROR", "Bluetooth scan permission not granted", null)
            return
        }

        if (bluetoothAdapter?.isEnabled != true) {
            result.error("BLUETOOTH_DISABLED", "Bluetooth is not enabled", null)
            return
        }

        bluetoothLeScanner = bluetoothAdapter.bluetoothLeScanner
        if (bluetoothLeScanner == null) {
            result.error("SCANNER_ERROR", "Bluetooth LE scanner not available", null)
            return
        }

        val requestedMacId = call.argument<String>("macId")?.takeUnless { it.isBlank() }
        val legacyDeviceId = call.argument<String>("deviceId")?.takeUnless { it.isBlank() }
        if (requestedMacId != null &&
            legacyDeviceId != null &&
            !requestedMacId.equals(legacyDeviceId, ignoreCase = true)
        ) {
            result.error(
                "INVALID_SCAN_FILTER",
                "macId and deviceId must match when both are provided",
                null
            )
            return
        }

        val targetMacId = requestedMacId ?: legacyDeviceId
        val targetServiceUuidRaw = call.argument<String>("uuid")?.takeUnless { it.isBlank() }
            ?: call.argument<String>("serviceUuid")?.takeUnless { it.isBlank() }
        val targetServiceUuid = try {
            targetServiceUuidRaw?.let(UUID::fromString)
        } catch (_: IllegalArgumentException) {
            result.error(
                "INVALID_SCAN_FILTER",
                "Invalid service UUID: $targetServiceUuidRaw",
                null
            )
            return
        }

        Log.i(TAG, "startDeviceScan: macId=$targetMacId, uuid=$targetServiceUuidRaw")
        stopScanInternal(sendEvent = false)

        activeScanTargetMacId = targetMacId
        activeScanServiceUuid = targetServiceUuid

        val scanFilters = buildScanFilters(
            targetMacId = targetMacId,
            targetServiceUuid = targetServiceUuid
        )
        val scanSettings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .build()

        try {
            bluetoothLeScanner?.startScan(scanFilters, scanSettings, scanCallback)
            sendScanEvent(BluetoothConnectionEventType.SCAN_STARTED)
            result.success(mapOf("scanning" to true, "message" to "Scan started"))

            mainHandler.postDelayed(stopScanRunnable, 15000)
        } catch (error: SecurityException) {
            activeScanTargetMacId = null
            activeScanServiceUuid = null
            result.error("SECURITY_ERROR", "Missing scan permission: ${error.message}", null)
        } catch (error: Exception) {
            activeScanTargetMacId = null
            activeScanServiceUuid = null
            result.error("SCAN_ERROR", "Failed to start scan: ${error.message}", null)
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopDeviceScan(result: MethodChannel.Result) {
        try {
            if (checkBluetoothPermissions()) {
                stopScanInternal(sendEvent = true)
                result.success(mapOf("scanning" to false, "message" to "Scan stopped"))
            } else {
                result.error("PERMISSION_ERROR", "Bluetooth permissions not granted", null)
            }
        } catch (error: Exception) {
            result.error("STOP_SCAN_ERROR", "Failed to stop scan: ${error.message}", null)
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopScanInternal(sendEvent: Boolean) {
        try {
            mainHandler.removeCallbacks(stopScanRunnable)
            bluetoothLeScanner?.stopScan(scanCallback)
        } catch (_: Exception) {
        } finally {
            activeScanTargetMacId = null
            activeScanServiceUuid = null
            if (sendEvent) {
                sendScanEvent(BluetoothConnectionEventType.SCAN_STOPPED)
            }
        }
    }

    private val scanCallback = object : ScanCallback() {
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult?) {
            result?.device?.let { device ->
                val advertisedName = result.scanRecord?.deviceName ?: device.name
                val targetMacId = activeScanTargetMacId
                val targetServiceUuid = activeScanServiceUuid
                val isTargetedMatch =
                    targetMacId != null && device.address.equals(
                        targetMacId,
                        ignoreCase = true
                    )
                val matchesServiceUuid =
                    targetServiceUuid != null &&
                            result.scanRecord?.serviceUuids?.any { it.uuid == targetServiceUuid } == true

                if (!shouldIncludeScanResult(
                        targetMacId = targetMacId,
                        targetServiceUuid = targetServiceUuid,
                        isTargetedMatch = isTargetedMatch,
                        matchesServiceUuid = matchesServiceUuid
                    )
                ) {
                    return
                }

                knownDeviceMacs.add(device.address)
                sendScanEvent(
                    type = BluetoothConnectionEventType.DEVICE_FOUND,
                    device = device,
                    deviceName = advertisedName
                )

                if (isTargetedMatch && (targetServiceUuid == null || matchesServiceUuid)) {
                    stopScanInternal(sendEvent = true)
                    connectToDevice(device)
                }
            }
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>?) {
            results?.forEach { result ->
                onScanResult(ScanSettings.CALLBACK_TYPE_ALL_MATCHES, result)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            mainHandler.removeCallbacks(stopScanRunnable)
            activeScanTargetMacId = null
            activeScanServiceUuid = null
            sendScanEvent(BluetoothConnectionEventType.SCAN_ERROR)
        }
    }

    private fun shouldIncludeScanResult(
        targetMacId: String?,
        targetServiceUuid: UUID?,
        isTargetedMatch: Boolean,
        matchesServiceUuid: Boolean
    ): Boolean {
        if (targetMacId == null && targetServiceUuid == null) {
            return true
        }

        if (targetMacId != null && !isTargetedMatch) {
            return false
        }

        if (targetServiceUuid != null && !matchesServiceUuid) {
            return false
        }

        return true
    }

    private fun buildScanFilters(
        targetMacId: String?,
        targetServiceUuid: UUID?
    ): List<ScanFilter> {
        if (targetMacId == null && targetServiceUuid == null) {
            return emptyList()
        }

        return listOf(
            ScanFilter.Builder().apply {
                if (targetMacId != null) {
                    setDeviceAddress(targetMacId)
                }
                if (targetServiceUuid != null) {
                    setServiceUuid(ParcelUuid(targetServiceUuid))
                }
            }.build()
        )
    }

    @SuppressLint("MissingPermission")
    private fun connectToDevice(device: BluetoothDevice) {
        if (!checkBluetoothPermissions()) {
            return
        }

        knownDeviceMacs.add(device.address)
        getOrCreateDevice(device.address).connect(device)
    }

    private fun setupBondingReceiver() {
        bondingReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == BluetoothDevice.ACTION_BOND_STATE_CHANGED) {
                    handleBondingStateChange(intent)
                }
            }
        }

        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(
                bondingReceiver,
                filter,
                Context.RECEIVER_NOT_EXPORTED
            )
        } else {
            @Suppress("DEPRECATION")
            context.registerReceiver(bondingReceiver, filter)
        }
        isReceiverRegistered = true
    }

    private fun unregisterBondingReceiver() {
        if (isReceiverRegistered && bondingReceiver != null) {
            try {
                context.unregisterReceiver(bondingReceiver)
            } catch (_: IllegalArgumentException) {
            } finally {
                isReceiverRegistered = false
            }
        }
    }

    @SuppressLint("MissingPermission", "NewApi")
    private fun handleBondingStateChange(intent: Intent) {
        val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        }

        val bondState =
            intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)

        if (!checkBluetoothPermissions() || device == null) {
            return
        }

        val deviceId = device.address
        val foundMac = knownDeviceMacs.contains(deviceId)

        if (!foundMac) {
            return
        }

        devices[deviceId]?.connection?.onBondingStateChanged(bondState)
    }

    @SuppressLint("MissingPermission")
    private fun sendScanEvent(
        type: BluetoothConnectionEventType,
        device: BluetoothDevice? = null,
        deviceName: String? = null
    ) {
        scope.launch {
            scanEventSink?.success(
                mapOf(
                    "type" to type.toStringValue(),
                    "deviceId" to device?.address,
                    "deviceName" to (deviceName ?: device?.name)
                )
            )
        }
    }

    private inner class ScanStreamHandler : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            scanEventSink = events
        }

        override fun onCancel(arguments: Any?) {
            scanEventSink = null
        }
    }

    private fun hasBlePermissions(): Boolean {
        return requiredBlePermissions().all(::hasPermission)
    }

    private fun requiredBlePermissions(): Array<String> {
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT
            )

            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M -> arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION
            )

            else -> emptyArray()
        }
    }

    private fun hasPermission(permission: String): Boolean {
        return ActivityCompat.checkSelfPermission(
            context,
            permission
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasBluetoothConnectPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            hasPermission(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            true
        }
    }

    private fun checkBluetoothPermissions(): Boolean {
        return hasBlePermissions()
    }

    @SuppressLint("MissingPermission")
    private fun buildGattConnectedDevices(): List<Map<String, Any?>> {
        val bonded = bluetoothAdapter?.bondedDevices?.toList().orEmpty()
        val connectedDevices = try {
            bluetoothManager.getConnectedDevices(BluetoothProfile.GATT)
        } catch (_: Exception) {
            emptyList()
        }

        return (connectedDevices + bonded)
            .distinctBy { it.address }
            .map { device ->
                val connectionState = try {
                    bluetoothManager.getConnectionState(device, BluetoothProfile.GATT)
                } catch (_: Exception) {
                    BluetoothProfile.STATE_DISCONNECTED
                }

                val deviceName = device.name ?: "Unknown Device"
                val isBonded = device.bondState == BluetoothDevice.BOND_BONDED

                mapOf(
                    "deviceId" to device.address,
                    "name" to deviceName,
                    "bonded" to isBonded,
                    "peripheralId" to device.address,
                    "peripheralName" to deviceName,
                    "isConnected" to (connectionState == BluetoothProfile.STATE_CONNECTED),
                    "state" to connectionState,
                    "bondState" to isBonded
                )
            }
    }

    fun cleanup() {
        try {
            unregisterBondingReceiver()
            detachActivity(cancelPendingResults = true)
            stopScanInternal(sendEvent = false)
            devices.values.forEach { it.connection.cleanup() }
            devices.clear()
        } catch (error: Exception) {
            Log.w(TAG, "Error during cleanup: ${error.message}")
        }

        pendingPermissionResult = null
        pendingEnableResult = null
        activeScanTargetMacId = null
        activeScanServiceUuid = null
        scanEventSink = null
        bondingReceiver = null
        methodChannel.setMethodCallHandler(null)
        scanEventChannel.setStreamHandler(null)
    }

    private fun detachActivity(cancelPendingResults: Boolean) {
        if (hasAttachedActivity) {
            activityBinding?.removeActivityResultListener(this)
            activityBinding?.removeRequestPermissionsResultListener(this)
        }

        if (cancelPendingResults) {
            pendingPermissionResult?.error(
                "ACTIVITY_DETACHED",
                "Bluetooth activity detached before the request completed",
                null
            )
            pendingEnableResult?.error(
                "ACTIVITY_DETACHED",
                "Bluetooth activity detached before the request completed",
                null
            )
            pendingPermissionResult = null
            pendingEnableResult = null
        }

        activityBinding = null
        activity = null
        hasAttachedActivity = false
    }
}

fun ByteArray.chunked(size: Int): List<ByteArray> {
    if (isEmpty()) {
        return emptyList()
    }

    val chunks = mutableListOf<ByteArray>()
    var index = 0
    while (index < this.size) {
        val end = minOf(index + size, this.size)
        chunks.add(copyOfRange(index, end))
        index += size
    }
    return chunks
}
