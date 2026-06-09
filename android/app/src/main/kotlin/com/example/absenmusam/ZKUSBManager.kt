package com.example.absenmusam

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import java.util.Random

/**
 * USB permission and hotplug management for ZKTeco devices.
 */
class ZKUSBManager(private val mContext: Context, private val zknirusbManagerListener: ZKUSBManagerListener) {
    private var vid = 0x1b55
    private var pid = 0
    private val ACTION_USB_PERMISSION: String = createRandomString(SOURCE_STRING, DEFAULT_LENGTH)
    private var mbRegisterFilter = false

    private val usbMgrReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val action = intent.action ?: return
            
            val device = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)

            if (ACTION_USB_PERMISSION == action) {
                if (device != null && device.vendorId == vid && device.productId == pid) {
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                        zknirusbManagerListener.onCheckPermission(0)
                    } else {
                        zknirusbManagerListener.onCheckPermission(-2)
                    }
                }
            } else if (UsbManager.ACTION_USB_DEVICE_ATTACHED == action) {
                if (device != null && device.vendorId == vid) {
                    zknirusbManagerListener.onUSBArrived(device)
                }
            } else if (UsbManager.ACTION_USB_DEVICE_DETACHED == action) {
                if (device != null && device.vendorId == vid) {
                    zknirusbManagerListener.onUSBRemoved(device)
                }
            }
        }
    }

    private fun isNullOrEmpty(target: String?): Boolean {
        return target == null || target.isEmpty()
    }

    private fun createRandomString(source: String, length: Int): String {
        if (isNullOrEmpty(source)) return ""
        val result = StringBuilder()
        val random = Random()
        for (index in 0 until length) {
            result.append(source[random.nextInt(source.length)])
        }
        return result.toString()
    }

    fun registerUSBPermissionReceiver(): Boolean {
        if (mbRegisterFilter) return false
        val filter = IntentFilter()
        filter.addAction(ACTION_USB_PERMISSION)
        filter.addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
        filter.addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            mContext.registerReceiver(usbMgrReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            mContext.registerReceiver(usbMgrReceiver, filter)
        }
        
        mbRegisterFilter = true
        return true
    }

    fun unRegisterUSBPermissionReceiver() {
        if (!mbRegisterFilter) return
        mContext.unregisterReceiver(usbMgrReceiver)
        mbRegisterFilter = false
    }

    fun initUSBPermission(vid: Int, pid: Int) {
        val usbManager = mContext.getSystemService(Context.USB_SERVICE) as UsbManager
        var usbDevice: UsbDevice? = null
        for (device in usbManager.deviceList.values) {
            if (device.vendorId == vid && device.productId == pid) {
                usbDevice = device
                break
            }
        }
        if (usbDevice == null) {
            zknirusbManagerListener.onCheckPermission(-1)
            return
        }
        this.vid = vid
        this.pid = pid
        if (!usbManager.hasPermission(usbDevice)) {
            val intent = Intent(ACTION_USB_PERMISSION)
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val pendingIntent = PendingIntent.getBroadcast(mContext, 0, intent, flags)
            usbManager.requestPermission(usbDevice, pendingIntent)
        } else {
            zknirusbManagerListener.onCheckPermission(0)
        }
    }

    companion object {
        private const val SOURCE_STRING = "0123456789-_abcdefghigklmnopqrstuvwxyzABCDEFGHIGKLMNOPQRSTUVWXYZ"
        private const val DEFAULT_LENGTH = 16
    }
}
