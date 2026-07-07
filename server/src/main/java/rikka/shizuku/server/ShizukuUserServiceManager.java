package rikka.shizuku.server;

import android.content.pm.PackageInfo;
import android.os.Bundle;
import android.os.IBinder;
import android.util.ArrayMap;

import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

import moe.shizuku.starter.ServiceStarter;
import rikka.shizuku.server.util.Android17Compat;
import rikka.hidden.compat.UserManagerApis;
import rikka.shizuku.server.util.UserHandleCompat;

public class ShizukuUserServiceManager extends UserServiceManager {

    private final Map<UserServiceRecord, ApkChangedListener> apkChangedListeners = new ArrayMap<>();
    private final Map<String, List<UserServiceRecord>> userServiceRecords = Collections.synchronizedMap(new ArrayMap<>());

    public ShizukuUserServiceManager() {
        super();
    }

    @Override
    public String getUserServiceStartCmd(
            UserServiceRecord record, String key, String token, String packageName,
            String classname, String processNameSuffix, int callingUid, boolean use32Bits, boolean debug) {

        String appProcess = "/system/bin/app_process";
        if (use32Bits && new File("/system/bin/app_process32").exists()) {
            appProcess = "/system/bin/app_process32";
        }
        return ServiceStarter.commandForUserService(
                appProcess,
                ShizukuService.getManagerApplicationInfo().sourceDir,
                ShizukuService.MANAGER_APPLICATION_ID,
                token, packageName, classname, processNameSuffix, callingUid, debug);
    }

    @Override
    public void attachUserService(IBinder binder, Bundle options) {
        try {
            super.attachUserService(binder, options);
        } catch (IllegalArgumentException e) {
            String message = e.getMessage();
            if (message != null && message.startsWith("unable to find token")) {
                // The record for this token was already evicted (e.g. by a
                // concurrent unbind/rebind, or the record's own start timeout)
                // before this attach arrived - see #201. Previously this
                // exception propagated back over binder to the caller (a
                // spawned ServiceStarter process, or an in-process caller like
                // ShizukuManagerProvider's own reconnect logic) and left that
                // connection stuck until the whole server was restarted.
                // Log and ignore instead: the caller sees no reply, same as
                // any other failed attach, and can retry normally on its next
                // bind - no restart required.
                LOGGER.w("attachUserService: %s (token already expired, ignoring)", message);
                return;
            }
            throw e;
        }
    }

    @Override
    public void onUserServiceRecordCreated(UserServiceRecord record, PackageInfo packageInfo) {
        super.onUserServiceRecordCreated(record, packageInfo);

        String packageName = packageInfo.packageName;
        ApkChangedListener listener = new ApkChangedListener() {
            @Override
            public void onApkChanged() {
                String newSourceDir = null;

                for (int userId : UserManagerApis.getUserIdsNoThrow()) {
                    PackageInfo pi = Android17Compat.getPackageInfo(packageName, 0, userId);
                    if (pi != null && pi.applicationInfo != null && pi.applicationInfo.sourceDir != null) {
                        newSourceDir = pi.applicationInfo.sourceDir;
                        break;
                    }
                }

                if (newSourceDir == null) {
                    LOGGER.v("remove record %s because package %s has been removed", record.token, packageName);
                    record.removeSelf();
                } else {
                    LOGGER.v("update apk listener for record %s since package %s is upgrading", record.token, packageName);
                    ApkChangedObservers.stop(this);
                    ApkChangedObservers.start(newSourceDir, this);
                }
            }
        };

        ApkChangedObservers.start(packageInfo.applicationInfo.sourceDir, listener);
        apkChangedListeners.put(record, listener);
    }

    @Override
    public void onUserServiceRecordRemoved(UserServiceRecord record) {
        super.onUserServiceRecordRemoved(record);
        ApkChangedListener listener = apkChangedListeners.get(record);
        if (listener != null) {
            ApkChangedObservers.stop(listener);
            apkChangedListeners.remove(record);
        }
    }
}
