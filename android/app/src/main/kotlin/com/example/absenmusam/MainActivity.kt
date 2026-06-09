package com.example.absenmusam

import android.content.Context
import android.graphics.Bitmap
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Bundle
import android.util.Base64
import android.util.Log
import androidx.annotation.NonNull
import com.zkteco.android.biometric.FingerprintExceptionListener
import com.zkteco.android.biometric.core.device.ParameterHelper
import com.zkteco.android.biometric.core.device.TransportType
import com.zkteco.android.biometric.core.utils.LogHelper
import com.zkteco.android.biometric.core.utils.ToolUtils
import com.zkteco.android.biometric.module.fingerprintreader.FingerprintCaptureListener
import com.zkteco.android.biometric.module.fingerprintreader.FingerprintSensor
import com.zkteco.android.biometric.module.fingerprintreader.FingprintFactory
import com.zkteco.android.biometric.module.fingerprintreader.ZKFingerService
import com.zkteco.android.biometric.module.fingerprintreader.exception.FingerprintException
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.*

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.absensimassal/fingerprint"
    private var fingerprintSensor: FingerprintSensor? = null
    private var zkusbManager: ZKUSBManager? = null
    private var bStarted = false
    private var bRegister = false
    private var enroll_index = 0
    private var isReseted = false
    private val deviceIndex = 0
    private var usb_vid = 0x1b55
    private var usb_pid = 0
    
    private val ENROLL_COUNT = 3
    private val regtemparray = Array(ENROLL_COUNT) { ByteArray(2048) }
    private var strUid: String? = null

    private var methodChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d("FingerSDK", "onCreate")
        
        zkusbManager = ZKUSBManager(applicationContext, object : ZKUSBManagerListener {
            override fun onCheckPermission(result: Int) {
                Log.d("FingerSDK", "onCheckPermission: $result")
                when (result) {
                    0 -> {
                        sendToFlutter("status", "Permission granted, opening device...")
                        openDevice()
                    }
                    -1 -> sendToFlutter("status", "Error: ZKTeco device disappeared from USB list")
                    -2 -> sendToFlutter("status", "Error: USB permission denied by user")
                    else -> sendToFlutter("status", "Error: USB permission failed (code $result)")
                }
            }

            override fun onUSBArrived(device: UsbDevice) {
                Log.d("FingerSDK", "onUSBArrived: VID=0x${Integer.toHexString(device.vendorId)} PID=0x${Integer.toHexString(device.productId)}")
                sendToFlutter("status", "USB device arrived: VID=0x${Integer.toHexString(device.vendorId)}")
                if (bStarted) {
                    closeDevice()
                }
                usb_vid = device.vendorId
                usb_pid = device.productId
                tryGetUSBPermission()
            }

            override fun onUSBRemoved(device: UsbDevice) {
                Log.d("FingerSDK", "onUSBRemoved: VID=0x${Integer.toHexString(device.vendorId)}")
                sendToFlutter("status", "USB Device removed")
                if (bStarted) {
                    closeDevice()
                }
            }
        })
        zkusbManager?.registerUSBPermissionReceiver()
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            Log.d("FingerSDK", "MethodCall: ${call.method}")
            when (call.method) {
                "requestPermission" -> {
                    if (enumSensor()) {
                        tryGetUSBPermission()
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "startScanner" -> {
                    if (bStarted) {
                        result.success("success")
                    } else {
                        val found = enumSensor()
                        if (found) {
                            tryGetUSBPermission()
                            result.success("success")
                        } else {
                            val usbMgr = getSystemService(Context.USB_SERVICE) as UsbManager
                            val sb = StringBuilder("ZKTeco sensor not found!\nUSB Device List (${usbMgr.deviceList.size}):\n")
                            for (d in usbMgr.deviceList.values) {
                                sb.append("• VID=0x${Integer.toHexString(d.vendorId)} PID=0x${Integer.toHexString(d.productId)}\n")
                            }
                            if (usbMgr.deviceList.isEmpty()) sb.append("• No USB devices detected")
                            result.success(sb.toString().trimEnd())
                        }
                    }
                }
                "stopScanner" -> {
                    closeDevice()
                    result.success("success")
                }
                "register" -> {
                    val userId = call.argument<String>("userId")
                    if (bStarted && userId != null) {
                        bRegister = true
                        strUid = userId
                        enroll_index = 0
                        result.success("success")
                    } else {
                        result.success("Scanner not started or invalid ID")
                    }
                }
                "identify" -> {
                    if (bStarted) {
                        bRegister = false
                        enroll_index = 0
                        result.success("success")
                    } else {
                        result.success("Scanner not started")
                    }
                }
                "loadTemplates" -> {
                    try {
                        val templates = call.argument<List<Map<String, String>>>("templates")
                        templates?.forEach {
                            val memberId = it["memberId"]
                            val templateStr = it["template"]
                            if (memberId != null && templateStr != null) {
                                val blob = Base64.decode(templateStr, Base64.NO_WRAP)
                                val ret = ZKFingerService.save(blob, memberId)
                                Log.d("FingerSDK", "Loaded template for $memberId: ret=$ret")
                            }
                        }
                        result.success("success")
                    } catch (e: Exception) {
                        Log.e("FingerSDK", "loadTemplates error: ${e.message}")
                        result.error("ERR", e.message, null)
                    }
                }
                "delete" -> {
                    val userId = call.argument<String>("userId")
                    if (userId != null) {
                        ZKFingerService.del(userId)
                        result.success("success")
                    } else {
                        result.error("ERR", "ID required", null)
                    }
                }
                "clear" -> {
                    ZKFingerService.clear()
                    result.success("success")
                }
                "scanDevices" -> {
                    val usbMgr = getSystemService(Context.USB_SERVICE) as UsbManager
                    val sb = StringBuilder("USB Devices (${usbMgr.deviceList.size}):\n")
                    for (d in usbMgr.deviceList.values) {
                        sb.append("VID=0x${Integer.toHexString(d.vendorId)} PID=0x${Integer.toHexString(d.productId)} | ${d.deviceName}\n")
                    }
                    if (usbMgr.deviceList.isEmpty()) sb.append("(none)")
                    result.success(sb.toString().trimEnd())
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun enumSensor(): Boolean {
        val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        Log.d("FingerSDK", "Scanning for ZKTeco devices (VID=0x1b55 or 0x1b55)...")
        for (device in usbManager.deviceList.values) {
            Log.d("FingerSDK", "Found USB: VID=0x${Integer.toHexString(device.vendorId)} PID=0x${Integer.toHexString(device.productId)}")
            if (device.vendorId == 0x1b55 || device.vendorId == 6997) {
                usb_vid = device.vendorId
                usb_pid = device.productId
                Log.d("FingerSDK", "ZKTeco sensor matched!")
                return true
            }
        }
        return false
    }

    private fun tryGetUSBPermission() {
        Log.d("FingerSDK", "tryGetUSBPermission VID=0x${Integer.toHexString(usb_vid)} PID=0x${Integer.toHexString(usb_pid)}")
        zkusbManager?.initUSBPermission(usb_vid, usb_pid)
    }

    private fun openDevice() {
        Log.d("FingerSDK", "openDevice")
        createFingerprintSensor()
        bRegister = false
        enroll_index = 0
        isReseted = false
        try {
            fingerprintSensor?.open(deviceIndex)
            fingerprintSensor?.setFingerprintCaptureListener(deviceIndex, fingerprintCaptureListener)
            fingerprintSensor?.SetFingerprintExceptionListener(fingerprintExceptionListener)
            fingerprintSensor?.startCapture(deviceIndex)
            bStarted = true
            Log.d("FingerSDK", "Device opened and capture started")
            sendToFlutter("status", "connect success!")
        } catch (e: FingerprintException) {
            Log.e("FingerSDK", "Open failed: ${e.message} (code=${e.errorCode})")
            try {
                fingerprintSensor?.openAndReboot(deviceIndex)
                Log.d("FingerSDK", "openAndReboot attempted")
            } catch (ex: Exception) {
                Log.e("FingerSDK", "openAndReboot failed: ${ex.message}")
            }
            sendToFlutter("status", "connect failed! ${e.message}")
        } catch (e: Exception) {
            Log.e("FingerSDK", "Unexpected open error: ${e.message}")
            sendToFlutter("status", "connect failed! ${e.message}")
        }
    }

    private fun createFingerprintSensor() {
        Log.d("FingerSDK", "createFingerprintSensor")
        if (fingerprintSensor != null) {
            closeDevice()
            FingprintFactory.destroy(fingerprintSensor)
            fingerprintSensor = null
        }
        val params = HashMap<String, Any>()
        params[ParameterHelper.PARAM_KEY_VID] = usb_vid
        params[ParameterHelper.PARAM_KEY_PID] = usb_pid
        fingerprintSensor = FingprintFactory.createFingerprintSensor(applicationContext, TransportType.USB, params)
    }

    private fun closeDevice() {
        Log.d("FingerSDK", "closeDevice")
        if (bStarted) {
            try {
                fingerprintSensor?.stopCapture(deviceIndex)
                fingerprintSensor?.close(deviceIndex)
            } catch (e: Exception) {
                Log.e("FingerSDK", "Error closing: ${e.message}")
            } finally {
                bStarted = false
            }
        }
    }

    private val fingerprintCaptureListener = object : FingerprintCaptureListener {
        override fun captureOK(fpImage: ByteArray?) {
            try {
                Log.d("FingerSDK", "captureOK, size=${fpImage?.size ?: 0}")
                if (fpImage == null) return
                val sensor = fingerprintSensor ?: return
                val width = sensor.imageWidth
                val height = sensor.imageHeight
                if (width <= 0 || height <= 0) {
                    Log.e("FingerSDK", "Invalid image dimensions: ${width}x${height}")
                    return
                }

                val bitmap = ToolUtils.renderCroppedGreyScaleBitmap(fpImage, width, height) ?: run {
                    Log.e("FingerSDK", "Bitmap rendering failed")
                    return
                }
                val stream = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                val byteArray = stream.toByteArray()
                
                runOnUiThread {
                    methodChannel?.invokeMethod("onImage", byteArray)
                }
            } catch (e: Throwable) {
                Log.e("FingerSDK", "CRASH PREVENTED in captureOK: ${e.message}")
                e.printStackTrace()
            }
        }

        override fun captureError(e: FingerprintException?) {
            try {
                Log.e("FingerSDK", "captureError: ${e?.message} (code=${e?.errorCode})")
                sendToFlutter("status", "Capture error: ${e?.message ?: "Unknown error"}")
            } catch (ex: Throwable) {
                Log.e("FingerSDK", "CRASH PREVENTED in captureError: ${ex.message}")
            }
        }

        override fun extractOK(fpTemplate: ByteArray?) {
            try {
                Log.d("FingerSDK", "extractOK, size=${fpTemplate?.size ?: 0}")
                if (fpTemplate == null) return
                if (bRegister) {
                    doRegister(fpTemplate)
                } else {
                    doIdentify(fpTemplate)
                }
            } catch (e: Throwable) {
                Log.e("FingerSDK", "CRASH PREVENTED in extractOK: ${e.message}")
            }
        }

        override fun extractError(i: Int) {
            try {
                Log.e("FingerSDK", "extractError: $i")
                sendToFlutter("status", "Extract error: $i")
            } catch (e: Throwable) {
                Log.e("FingerSDK", "CRASH PREVENTED in extractError: ${e.message}")
            }
        }
    }

    private fun doRegister(template: ByteArray) {
        try {
            val bufids = ByteArray(256)
            var ret = ZKFingerService.identify(template, bufids, 70, 1)
            if (ret > 0) {
                val strRes = String(bufids).split("\t")
                sendToFlutter("status", "Finger already enrolled by ${strRes[0]}")
                bRegister = false
                enroll_index = 0
                return
            }
            if (enroll_index > 0 && ZKFingerService.verify(regtemparray[enroll_index - 1], template) <= 0) {
                sendToFlutter("status", "Please press same finger 3 times")
                bRegister = false
                enroll_index = 0
                return
            }
            System.arraycopy(template, 0, regtemparray[enroll_index], 0, 2048)
            enroll_index++
            if (enroll_index == ENROLL_COUNT) {
                bRegister = false
                enroll_index = 0
                val regTemp = ByteArray(2048)
                ret = ZKFingerService.merge(regtemparray[0], regtemparray[1], regtemparray[2], regTemp)
                if (ret > 0) {
                    val retVal = ZKFingerService.save(regTemp, strUid)
                    if (retVal == 0) {
                        val base64Template = Base64.encodeToString(regTemp, 0, ret, Base64.NO_WRAP)
                        sendToFlutter("onRegisterSuccess", base64Template)
                        sendToFlutter("status", "Registration successful")
                    } else {
                        sendToFlutter("status", "Save failed: $retVal")
                    }
                } else {
                    sendToFlutter("status", "Merge failed")
                }
            } else {
                sendToFlutter("status", "Press finger again (${enroll_index + 1}/3)")
            }
        } catch (e: Throwable) {
            Log.e("FingerSDK", "CRASH PREVENTED in doRegister: ${e.message}")
        }
    }

    private fun doIdentify(template: ByteArray) {
        try {
            val bufids = ByteArray(256)
            val ret = ZKFingerService.identify(template, bufids, 70, 1)
            if (ret > 0) {
                val strRes = String(bufids).split("\t")
                if (strRes.size >= 2) {
                    val result = HashMap<String, Any>()
                    result["memberId"] = strRes[0].trim()
                    result["score"] = strRes[1].trim().toIntOrNull() ?: 0
                    sendToFlutter("onIdentifyResult", result)
                    sendToFlutter("status", "Identify success: ${strRes[0].trim()}")
                } else {
                    sendToFlutter("status", "Identify format error")
                }
            } else {
                sendToFlutter("status", "Not recognized")
            }
        } catch (e: Throwable) {
            Log.e("FingerSDK", "CRASH PREVENTED in doIdentify: ${e.message}")
        }
    }

    private val fingerprintExceptionListener = FingerprintExceptionListener {
        try {
            Log.e("FingerSDK", "FingerprintExceptionListener triggered")
            if (!isReseted) {
                try {
                    fingerprintSensor?.openAndReboot(deviceIndex)
                } catch (e: Exception) {}
                isReseted = true
            }
        } catch (e: Throwable) {
            Log.e("FingerSDK", "CRASH PREVENTED in exceptionListener: ${e.message}")
        }
    }

    private fun sendToFlutter(method: String, arguments: Any?) {
        runOnUiThread {
            try {
                methodChannel?.invokeMethod(method, arguments)
            } catch (e: Exception) {
                Log.e("FingerSDK", "invokeMethod error: ${e.message}")
            }
        }
    }

    override fun onDestroy() {
        Log.d("FingerSDK", "onDestroy")
        zkusbManager?.unRegisterUSBPermissionReceiver()
        closeDevice()
        super.onDestroy()
    }
}
