package moe.shizuku.starter;

import android.content.IContentProvider;
import android.os.Binder;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;
import android.util.Pair;

import java.util.Locale;

import moe.shizuku.api.BinderContainer;
import moe.shizuku.starter.util.IContentProviderCompat;
import rikka.hidden.compat.ActivityManagerApis;
import rikka.shizuku.ShizukuApiConstants;
import rikka.shizuku.starter.BuildConfig;
import rikka.shizuku.server.UserService;

public class ServiceStarter {

    private static final String TAG = "ShizukuServiceStarter";

    private static final String EXTRA_BINDER = "moe.shizuku.privileged.api.intent.extra.BINDER";

    // Backoff (ms) between getContentProviderExternal retries when the manager's
    // provider is momentarily unpublished (process cached/frozen or still
    // starting). One lookup happens before the first sleep, so this is 4 retries
    // for 5 total attempts and ~3.25s of added wait at most. See #201.
    private static final long[] NULL_PROVIDER_RETRY_BACKOFF_MS = {250, 500, 1000, 1500};

    public static final String DEBUG_ARGS;

    static {
        int sdk = Build.VERSION.SDK_INT;
        if (sdk >= 30) {
            DEBUG_ARGS = "-Xcompiler-option" + " --debuggable" +
                    " -XjdwpProvider:adbconnection" +
                    " -XjdwpOptions:suspend=n,server=y";
        } else if (sdk >= 28) {
            DEBUG_ARGS = "-Xcompiler-option" + " --debuggable" +
                    " -XjdwpProvider:internal" +
                    " -XjdwpOptions:transport=dt_android_adb,suspend=n,server=y";
        } else {
            DEBUG_ARGS = "-Xcompiler-option" + " --debuggable" +
                    " -agentlib:jdwp=transport=dt_android_adb,suspend=n,server=y";
        }
    }

    private static final String USER_SERVICE_CMD_FORMAT = "(CLASSPATH='%s' %s%s /system/bin " +
            "--nice-name='%s' moe.shizuku.starter.ServiceStarter " +
            "--manager='%s' --token='%s' --package='%s' --class='%s' --uid=%d%s)&";

    // DeathRecipient will automatically be unlinked when all references to the
    // binder is dropped, so we hold the reference here.
    @SuppressWarnings("FieldCanBeLocal")
    private static IBinder shizukuBinder;

    public static String commandForUserService(String appProcess, String managerApkPath, String managerPackageName, String token, String packageName, String classname, String processNameSuffix, int callingUid, boolean debug) {
        String processName = String.format("%s:%s", packageName, processNameSuffix);
        return String.format(Locale.ENGLISH, USER_SERVICE_CMD_FORMAT,
                managerApkPath, appProcess, debug ? (" " + DEBUG_ARGS) : "",
                processName,
                managerPackageName, token, packageName, classname, callingUid, debug ? (" " + "--debug-name=" + processName) : "");
    }

    private static String managerPackageName = BuildConfig.MANAGER_APPLICATION_ID;

    public static void main(String[] args) {
        if (Looper.getMainLooper() == null) {
            Looper.prepareMainLooper();
        }

        for (String arg : args) {
            if (arg.startsWith("--manager=")) {
                managerPackageName = arg.substring("--manager=".length());
            }
        }

        IBinder service;
        String token;

        UserService.setTag(TAG);
        Pair<IBinder, String> result = UserService.create(args);

        if (result == null) {
            System.exit(1);
            return;
        }

        service = result.first;
        token = result.second;

        if (!sendBinder(service, token)) {
            System.exit(1);
        }

        Looper.loop();
        System.exit(0);

        Log.i(TAG, "service exited");
    }

    private static boolean sendBinder(IBinder binder, String token) {
        return sendBinder(binder, token, true);
    }

    private static boolean sendBinder(IBinder binder, String token, boolean retry) {
        String name = managerPackageName + ".shizuku";
        int userId = 0;
        IContentProvider provider = null;

        try {
            // The manager app's ShizukuProvider may not be published at the moment
            // we look it up: its process can be cached/frozen (commonly under
            // battery optimization) or still starting, in which case
            // getContentProviderExternal returns null. Previously we gave up and
            // returned false immediately, which made main() exit(1) and left the
            // spawned UserService unable to (re)connect until Shizuku was restarted
            // (issue #201). Retry the lookup a few times with a short backoff so a
            // momentarily unavailable manager can resolve on its own.
            //
            // Unlike the "provider is dead" path below, do NOT force-stop the
            // manager here: there is no stale provider record to clear, and killing
            // a merely-frozen manager can push it into the stopped state and make
            // the provider unavailable for good.
            for (int attempt = 0; ; attempt++) {
                provider = ActivityManagerApis.getContentProviderExternal(name, userId, null, name);
                if (provider != null) {
                    break;
                }
                if (attempt >= NULL_PROVIDER_RETRY_BACKOFF_MS.length) {
                    Log.e(TAG, String.format("provider is null %s %d (gave up after %d attempts)", name, userId, attempt + 1));
                    return false;
                }
                long backoff = NULL_PROVIDER_RETRY_BACKOFF_MS[attempt];
                Log.w(TAG, String.format("provider is null %s %d, retrying in %dms (attempt %d/%d)",
                        name, userId, backoff, attempt + 1, NULL_PROVIDER_RETRY_BACKOFF_MS.length + 1));
                Thread.sleep(backoff);
            }

            if (!provider.asBinder().pingBinder()) {
                Log.e(TAG, String.format("provider is dead %s %d", name, userId));

                if (retry) {
                    // For unknown reason, sometimes this could happens
                    // Kill Shizuku app and try again could work
                    ActivityManagerApis.forceStopPackageNoThrow(managerPackageName, userId);
                    Log.e(TAG, String.format("kill %s in user %d and try again", managerPackageName, userId));
                    Thread.sleep(1000);
                    return sendBinder(binder, token, false);
                }
                return false;
            }

            if (!retry) {
                Log.e(TAG, "retry works");
            }

            Bundle extra = new Bundle();
            extra.putParcelable(EXTRA_BINDER, new BinderContainer(binder));
            extra.putString(ShizukuApiConstants.USER_SERVICE_ARG_TOKEN, token);

            Bundle reply = IContentProviderCompat.call(provider, null, null, name, "sendUserService", null, extra);

            if (reply != null) {
                reply.setClassLoader(BinderContainer.class.getClassLoader());

                Log.i(TAG, String.format("send binder to %s in user %d", managerPackageName, userId));
                BinderContainer container = reply.getParcelable(EXTRA_BINDER);

                if (container != null && container.binder != null && container.binder.pingBinder()) {
                    shizukuBinder = container.binder;
                    shizukuBinder.linkToDeath(() -> {
                        Log.i(TAG, "exiting...");
                        System.exit(0);
                    }, 0);
                    return true;
                } else {
                    Log.w(TAG, "server binder not received");
                }
            }

            return false;
        } catch (Throwable tr) {
            Log.e(TAG, String.format("failed send binder to %s in user %d", managerPackageName, userId), tr);
            return false;
        } finally {
            if (provider != null) {
                try {
                    ActivityManagerApis.removeContentProviderExternal(name, null);
                } catch (Throwable tr) {
                    Log.w(TAG, "removeContentProviderExternal", tr);
                }
            }
        }
    }
}
