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
import rikka.shizuku.ShizukuApiConstants;
import rikka.shizuku.server.util.Android17Compat;
import rikka.hidden.compat.UserManagerApis;
import rikka.shizuku.server.util.UserHandleCompat;

public class ShizukuUserServiceManager extends UserServiceManager {

    // ---- [REPRO INSTRUMENTATION for issue #201 - NOT for release] ----------
    // The token race is a short window: a user-service process attaches with a
    // token whose record was evicted (unbind / rebind / start timeout) during
    // the gap between spawning the process and it attaching. On a fast device
    // that window is only tens of milliseconds, so it is practically impossible
    // to hit by hand. Artificially widening it to a couple of seconds lets a
    // normal-speed unbind/rebind land inside it on any device/emulator, so the
    // FIX on this branch can be proven to absorb the race deterministically.
    // This constant only exists on the throwaway test-harness branch; set to 0
    // for normal behaviour. Never merge this file into a release/PR branch.
    private static final long REPRO_SPAWN_DELAY_MS = 2000;
    // ------------------------------------------------------------------------

    private final Map<UserServiceRecord, ApkChangedListener> apkChangedListeners = new ArrayMap<>();
    private final Map<String, List<UserServiceRecord>> userServiceRecords = Collections.synchronizedMap(new ArrayMap<>());

    public ShizukuUserServiceManager() {
        super();
    }

    @Override
    public String getUserServiceStartCmd(
            UserServiceRecord record, String key, String token, String packageName,
            String classname, String processNameSuffix, int callingUid, boolean use32Bits, boolean debug) {

        // [REPRO] Delay the actual process launch to widen the spawn->attach
        // window. This runs on the user-service executor thread and does NOT
        // hold the manager lock, so an incoming unbind/rebind can act on this
        // record's token before the delayed process attaches - exactly the
        // condition the #201 fix handles gracefully.
        if (REPRO_SPAWN_DELAY_MS > 0) {
            LOGGER.w("[repro] delaying user-service spawn %d ms for token=%s (unbind/rebind now to trigger the race)", REPRO_SPAWN_DELAY_MS, token);
            try {
                Thread.sleep(REPRO_SPAWN_DELAY_MS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }

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
        // [REPRO] Surface the attach outcome in logcat so the harness can prove
        // the raced attach now completes instead of wedging. With the #201 fix
        // present, super.attachUserService no longer throws "unable to find
        // token" - it completes (or the orphaned binder self-destructs), so the
        // [repro] REPRODUCED branch below must NOT fire.
        String token = options != null ? options.getString(ShizukuApiConstants.USER_SERVICE_ARG_TOKEN) : null;
        LOGGER.w("[repro] attachUserService token=%s", token);
        try {
            super.attachUserService(binder, options);
            LOGGER.w("[repro] attach OK for token=%s", token);
        } catch (IllegalArgumentException e) {
            LOGGER.e(e, "[repro] REPRODUCED #201: unable to find token %s (record evicted during the spawn window)", token);
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
