# -----------------------------------------------------------------------------
# Windows Terminal Services P/Invoke surface
#
# Registers LISSTech.Wts.* types into the AppDomain. Runspaces inherit the
# AppDomain so one registration is visible to all subsequent workers.
# -----------------------------------------------------------------------------

if ('LISSTech.Wts.Native' -as [type]) {
    Write-Debug 'Types.ps1 → WTS types already registered, skipping'
    return
}

Write-Debug 'Types.ps1 → registering WTS P/Invoke surface'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace LISSTech.Wts
{
    public enum WtsConnectState
    {
        Active       = 0,
        Connected    = 1,
        ConnectQuery = 2,
        Shadow       = 3,
        Disconnected = 4,
        Idle         = 5,
        Listen       = 6,
        Reset        = 7,
        Down         = 8,
        Init         = 9
    }

    public enum WtsInfoClass
    {
        SessionInfo = 24
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WTS_SESSION_INFO
    {
        public int SessionId;
        [MarshalAs(UnmanagedType.LPWStr)]
        public string WinStationName;
        public WtsConnectState State;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WTSINFO
    {
        public WtsConnectState State;
        public int  SessionId;
        public uint IncomingBytes;
        public uint OutgoingBytes;
        public uint IncomingFrames;
        public uint OutgoingFrames;
        public uint IncomingCompressedBytes;
        public uint OutgoingCompressedBytes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string WinStationName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)] public string Domain;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 21)] public string UserName;
        public long ConnectTime;
        public long DisconnectTime;
        public long LastInputTime;
        public long LogonTime;
        public long CurrentTime;
    }

    public static class Native
    {
        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr WTSOpenServerW(string pServerName);

        [DllImport("wtsapi32.dll")]
        public static extern void WTSCloseServer(IntPtr hServer);

        [DllImport("wtsapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool WTSEnumerateSessionsW(
            IntPtr hServer, int Reserved, int Version,
            out IntPtr ppSessionInfo, out int pCount);

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool WTSQuerySessionInformationW(
            IntPtr hServer, int sessionId, WtsInfoClass infoClass,
            out IntPtr ppBuffer, out int pBytesReturned);

        [DllImport("wtsapi32.dll")]
        public static extern void WTSFreeMemory(IntPtr pMemory);

        [DllImport("wtsapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool WTSLogoffSession(
            IntPtr hServer, int sessionId,
            [MarshalAs(UnmanagedType.Bool)] bool bWait);
    }
}
'@
