using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace TokenMihariban.Sync;

/// <summary>Protects the Firebase refresh token with Windows DPAPI for the current user.</summary>
internal static class WindowsCredentialProtector
{
    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob { public int Size; public IntPtr Data; }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref DataBlob dataIn, string? description, IntPtr optionalEntropy, IntPtr reserved, IntPtr promptStruct, int flags, out DataBlob dataOut);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob dataIn, IntPtr description, IntPtr optionalEntropy, IntPtr reserved, IntPtr promptStruct, int flags, out DataBlob dataOut);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static string? Protect(string value)
    {
        try { return Convert.ToBase64String(Transform(Encoding.UTF8.GetBytes(value), true)); }
        catch { return null; }
    }

    public static string? Unprotect(string value)
    {
        try { return Encoding.UTF8.GetString(Transform(Convert.FromBase64String(value), false)); }
        catch { return null; }
    }

    private static byte[] Transform(byte[] input, bool protect)
    {
        var inputPointer = Marshal.AllocHGlobal(input.Length);
        var output = new DataBlob();
        try
        {
            Marshal.Copy(input, 0, inputPointer, input.Length);
            var inputBlob = new DataBlob { Size = input.Length, Data = inputPointer };
            var succeeded = protect
                ? CryptProtectData(ref inputBlob, "TokenMihariban Firebase Authentication", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, out output)
                : CryptUnprotectData(ref inputBlob, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, out output);
            if (!succeeded) throw new Win32Exception(Marshal.GetLastWin32Error());
            var result = new byte[output.Size];
            Marshal.Copy(output.Data, result, 0, output.Size);
            return result;
        }
        finally
        {
            Marshal.FreeHGlobal(inputPointer);
            if (output.Data != IntPtr.Zero) LocalFree(output.Data);
        }
    }
}
