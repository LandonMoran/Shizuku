package moe.shizuku.manager.repro

import android.os.Binder

/**
 * Trivial user-service payload used only to drive issue #201
 * (UserServiceManager "unable to find token" race). It carries no logic;
 * the server never needs to call into it for the repro to fire - only the
 * bind/unbind/attach lifecycle around it matters.
 */
class Repro201Service : Binder()
