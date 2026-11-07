// SPDX-License-Identifier: MIT
// Own interop declarations; no vendor SDK implementation is bundled.
// Compatible with Windows PowerShell 5.1 Add-Type and PowerShell 7.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace LanAudioBridge.WindowsAudio
{
    public sealed class EndpointInfo
    {
        public string Id { get; internal set; }
        public string Name { get; internal set; }
        public bool Active { get; internal set; }
        public uint State { get; internal set; }
        public string WaveInterface { get; internal set; }
        public string ParentDevice { get; internal set; }
    }

    public static class Endpoints
    {
        // Roles: 0 = console, 1 = multimedia, 2 = communications.
        public static EndpointInfo[] ListRender() { return List(0); }

        // Recording endpoints (flow 1), for example to replace a virtual default microphone.
        public static EndpointInfo[] ListCapture() { return List(1); }

        private static EndpointInfo[] List(int flow)
        {
            IMMDeviceEnumerator enumerator = null;
            IMMDeviceCollection devices = null;
            try
            {
                enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
                Check(enumerator.EnumAudioEndpoints(flow, 15, out devices), "Enumerate audio endpoints");
                uint count;
                Check(devices.GetCount(out count), "Count render endpoints");
                List<EndpointInfo> result = new List<EndpointInfo>();
                for (uint i = 0; i < count; i++)
                {
                    IMMDevice device = null;
                    IPropertyStore properties = null;
                    try
                    {
                        Check(devices.Item(i, out device), "Read render endpoint");
                        string id;
                        uint state;
                        Check(device.GetId(out id), "Read endpoint ID");
                        Check(device.GetState(out state), "Read endpoint state");
                        int storeResult = device.OpenPropertyStore(0, out properties);
                        if ((state & 1) != 0) Check(storeResult, "Open endpoint properties");
                        PropertyKey key = new PropertyKey(new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), 14);
                        PropVariant value = new PropVariant();
                        string name;
                        try
                        {
                            int propertyResult = storeResult < 0 ? storeResult : properties.GetValue(ref key, out value);
                            // Stale/unplugged endpoints can retain an ID while their
                            // device property provider is no longer available.
                            if ((state & 1) != 0) Check(propertyResult, "Read endpoint friendly name");
                            name = propertyResult >= 0 && value.VariantType == 31 && value.Pointer != IntPtr.Zero
                                ? Marshal.PtrToStringUni(value.Pointer) : id;
                        }
                        finally { PropVariantClear(ref value); }
                        result.Add(new EndpointInfo
                        {
                            Id = id, Name = name, Active = (state & 1) != 0, State = state,
                            WaveInterface = storeResult < 0 ? null : ReadOptionalString(properties,
                                new PropertyKey(new Guid("233164c8-1b2c-4c7d-bc68-b671687a2567"), 1)),
                            ParentDevice = storeResult < 0 ? null : ReadOptionalString(properties,
                                new PropertyKey(new Guid("b3f8fa53-0004-438e-9003-51a46e139bfc"), 2))
                        });
                    }
                    finally { Release(properties); Release(device); }
                }
                return result.ToArray();
            }
            finally { Release(devices); Release(enumerator); }
        }

        // Device description (the first part of the Sound settings name, e.g. "Speakers").
        // Writing requires administrator rights; Windows keeps it per endpoint.
        public static string GetDescription(string id)
        {
            ValidateEndpointId(id);
            IMMDeviceEnumerator enumerator = null; IMMDevice device = null; IPropertyStore properties = null;
            try
            {
                enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
                Check(enumerator.GetDevice(id, out device), "Open endpoint");
                Check(device.OpenPropertyStore(0, out properties), "Open endpoint properties");
                return ReadOptionalString(properties, DeviceDescription);
            }
            finally { Release(properties); Release(device); Release(enumerator); }
        }

        public static void SetDescription(string id, string text)
        {
            ValidateEndpointId(id);
            if (String.IsNullOrWhiteSpace(text) || text.Length > 64 || text.IndexOf('\0') >= 0)
                throw new ArgumentException("A short, nonempty description is required.", "text");
            IMMDeviceEnumerator enumerator = null; IMMDevice device = null; IPropertyStore properties = null;
            PropVariant value = new PropVariant { VariantType = 31, Pointer = Marshal.StringToCoTaskMemUni(text) };
            try
            {
                enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
                Check(enumerator.GetDevice(id, out device), "Open endpoint");
                Check(device.OpenPropertyStore(2, out properties), "Open endpoint properties for writing");
                PropertyKey key = DeviceDescription;
                Check(properties.SetValue(ref key, ref value), "Set endpoint description");
                Check(properties.Commit(), "Save endpoint description");
            }
            finally { PropVariantClear(ref value); Release(properties); Release(device); Release(enumerator); }
        }

        private static readonly PropertyKey DeviceDescription = new PropertyKey(new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), 2);

        public static string GetDefault(int role) { return GetDefault(0, role); }

        public static string GetDefaultCapture(int role) { return GetDefault(1, role); }

        private static string GetDefault(int flow, int role)
        {
            ValidateRole(role);
            IMMDeviceEnumerator enumerator = null;
            IMMDevice device = null;
            try
            {
                enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
                int hr = enumerator.GetDefaultAudioEndpoint(flow, role, out device);
                if (hr == unchecked((int)0x80070490)) return null; // No default exists.
                Check(hr, "Read default endpoint");
                string id;
                Check(device.GetId(out id), "Read default endpoint ID");
                return id;
            }
            finally { Release(device); Release(enumerator); }
        }

        public static uint GetState(string id)
        {
            ValidateEndpointId(id);
            IMMDeviceEnumerator enumerator = null;
            IMMDevice device = null;
            try
            {
                enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
                Check(enumerator.GetDevice(id, out device), "Find audio endpoint");
                uint state;
                Check(device.GetState(out state), "Read endpoint state");
                return state;
            }
            finally { Release(device); Release(enumerator); }
        }

        public static void SetVisibility(string id, bool visible)
        {
            ValidateEndpointId(id);
            IPolicyConfig policy = null;
            try
            {
                // Undocumented Windows desktop interface. The caller owns backup,
                // endpoint selection, and verification of the resulting state.
                policy = (IPolicyConfig)new PolicyConfigClient();
                Check(policy.SetEndpointVisibility(id, visible ? 1 : 0), "Set audio endpoint visibility");
            }
            finally { Release(policy); }
        }

        public static void SetDefault(string id, int role)
        {
            ValidateRole(role);
            ValidateEndpointId(id);
            IPolicyConfig policy = null;
            try
            {
                // Undocumented Windows desktop interface. Fail explicitly if unsupported;
                // do not silently change other roles or substitute another endpoint.
                policy = (IPolicyConfig)new PolicyConfigClient();
                Check(policy.SetDefaultEndpoint(id, role), "Set default render endpoint for role " + role);
            }
            finally { Release(policy); }
        }

        private static string ReadOptionalString(IPropertyStore properties, PropertyKey key)
        {
            if (properties == null) return null;
            PropVariant value = new PropVariant();
            try
            {
                int hr = properties.GetValue(ref key, out value);
                return hr >= 0 && value.VariantType == 31 && value.Pointer != IntPtr.Zero
                    ? Marshal.PtrToStringUni(value.Pointer) : null;
            }
            catch (COMException) { return null; }
            finally { PropVariantClear(ref value); }
        }

        private static void ValidateEndpointId(string id)
        {
            if (String.IsNullOrWhiteSpace(id) || id.IndexOf('\0') >= 0)
                throw new ArgumentException("A nonempty endpoint ID is required.", "id");
        }

        private static void ValidateRole(int role)
        {
            if (role < 0 || role > 2) throw new ArgumentOutOfRangeException("role", "Use 0, 1, or 2.");
        }
        private static void Check(int hr, string operation)
        {
            if (hr < 0) throw new COMException(operation + " failed (0x" + hr.ToString("X8") + ").", hr);
        }
        private static void Release(object value)
        {
            if (value != null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value);
        }

        [DllImport("ole32.dll", ExactSpelling = true)]
        private static extern int PropVariantClear(ref PropVariant value);

        [StructLayout(LayoutKind.Sequential)]
        private struct PropertyKey
        {
            public Guid Format;
            public uint Id;
            public PropertyKey(Guid format, uint id) { Format = format; Id = id; }
        }
        // 24 bytes accommodates the largest native PROPVARIANT on x64; native x86
        // uses only the first 16 bytes. This struct is passed by reference only.
        [StructLayout(LayoutKind.Explicit, Size = 24)]
        private struct PropVariant
        {
            [FieldOffset(0)] public ushort VariantType;
            [FieldOffset(8)] public IntPtr Pointer;
        }
        [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
        private class MMDeviceEnumerator { }
        [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDeviceEnumerator
        {
            [PreserveSig] int EnumAudioEndpoints(int flow, uint stateMask, out IMMDeviceCollection devices);
            [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice device);
            [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
            [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
            [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
        }
        [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDeviceCollection
        {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int Item(uint index, out IMMDevice device);
        }
        [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDevice
        {
            [PreserveSig] int Activate(ref Guid iid, uint context, IntPtr parameters, out IntPtr result);
            [PreserveSig] int OpenPropertyStore(uint mode, out IPropertyStore properties);
            [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
            [PreserveSig] int GetState(out uint state);
        }
        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore
        {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int GetAt(uint index, out PropertyKey key);
            [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
            [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
            [PreserveSig] int Commit();
        }
        [ComImport, Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
        private class PolicyConfigClient { }
        [ComImport, Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPolicyConfig
        {
            // Unused entries retain the native vtable ordering.
            [PreserveSig] int GetMixFormat(IntPtr id, IntPtr format);
            [PreserveSig] int GetDeviceFormat(IntPtr id, int defaultFormat, IntPtr format);
            [PreserveSig] int ResetDeviceFormat(IntPtr id);
            [PreserveSig] int SetDeviceFormat(IntPtr id, IntPtr endpointFormat, IntPtr mixFormat);
            [PreserveSig] int GetProcessingPeriod(IntPtr id, int defaultPeriod, IntPtr period, IntPtr minimum);
            [PreserveSig] int SetProcessingPeriod(IntPtr id, IntPtr period);
            [PreserveSig] int GetShareMode(IntPtr id, IntPtr mode);
            [PreserveSig] int SetShareMode(IntPtr id, IntPtr mode);
            [PreserveSig] int GetPropertyValue(IntPtr id, IntPtr key, IntPtr value);
            [PreserveSig] int SetPropertyValue(IntPtr id, IntPtr key, IntPtr value);
            [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
            [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string id, int visible);
        }
    }

    // Use one instance per process, and always Dispose (PowerShell: try/finally).
    // Setters are asynchronous: orchestration must poll Dirty and read back values.
    public sealed class VoicemeeterRemote : IDisposable
    {
        private readonly object gate = new object();
        private LibraryHandle library;
        private bool loggedIn;
        private NoArgs login, logout, dirty;
        private GetInt getType, getVersion;
        private GetFloatValue getFloat;
        private SetFloatValue setFloat;
        private GetStringValue getString;
        private SetStringValue setString;

        public VoicemeeterRemote(string dllPath)
        {
            if (String.IsNullOrWhiteSpace(dllPath) || !Path.IsPathRooted(dllPath) ||
                !String.Equals(Path.GetPathRoot(dllPath), Path.GetPathRoot(Path.GetFullPath(dllPath)), StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("An absolute DLL path is required.", "dllPath");
            string fullPath = Path.GetFullPath(dllPath);
            if (!File.Exists(fullPath)) throw new FileNotFoundException("Voicemeeter Remote DLL was not found.", fullPath);
            // Dependencies may resolve only beside this DLL and in System32.
            library = LoadLibraryEx(fullPath, IntPtr.Zero, 0x00000100 | 0x00000800);
            if (library.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                library.Dispose();
                throw new Win32Exception(error, "Could not load " + fullPath + "; select the DLL matching this process architecture.");
            }
            try
            {
                login = Bind<NoArgs>("VBVMR_Login");
                logout = Bind<NoArgs>("VBVMR_Logout");
                dirty = Bind<NoArgs>("VBVMR_IsParametersDirty");
                getType = Bind<GetInt>("VBVMR_GetVoicemeeterType");
                getVersion = Bind<GetInt>("VBVMR_GetVoicemeeterVersion");
                getFloat = Bind<GetFloatValue>("VBVMR_GetParameterFloat");
                setFloat = Bind<SetFloatValue>("VBVMR_SetParameterFloat");
                getString = Bind<GetStringValue>("VBVMR_GetParameterStringW");
                setString = Bind<SetStringValue>("VBVMR_SetParameterStringW");
            }
            catch { library.Dispose(); throw; }
        }

        public int Login()
        {
            lock (gate)
            {
                EnsureOpen();
                if (loggedIn) throw new InvalidOperationException("Login must be called only once per session.");
                int result = Check(login(), "Login");
                loggedIn = true; // 1 means registered successfully, but Voicemeeter is not running.
                return result;
            }
        }
        public int Logout()
        {
            lock (gate)
            {
                EnsureOpen();
                if (!loggedIn) return 0;
                int result = Check(logout(), "Logout");
                loggedIn = false;
                return result;
            }
        }
        public int Type()
        {
            lock (gate) { EnsureLoggedIn(); int value; Check(getType(out value), "GetVoicemeeterType"); return value; }
        }
        public int Version()
        {
            lock (gate) { EnsureLoggedIn(); int value; Check(getVersion(out value), "GetVoicemeeterVersion"); return value; }
        }
        public int Dirty()
        {
            lock (gate) { EnsureLoggedIn(); return Check(dirty(), "IsParametersDirty"); }
        }
        public float GetFloat(string parameter)
        {
            ValidateParameter(parameter);
            lock (gate) { EnsureLoggedIn(); float value; Check(getFloat(parameter, out value), "GetParameterFloat " + parameter); return value; }
        }
        public string GetString(string parameter)
        {
            ValidateParameter(parameter);
            lock (gate)
            {
                EnsureLoggedIn();
                StringBuilder value = new StringBuilder(512);
                Check(getString(parameter, value), "GetParameterStringW " + parameter);
                return value.ToString();
            }
        }
        public void SetFloat(string parameter, float value)
        {
            ValidateParameter(parameter);
            if (Single.IsNaN(value) || Single.IsInfinity(value)) throw new ArgumentOutOfRangeException("value");
            lock (gate) { EnsureLoggedIn(); Check(setFloat(parameter, value), "SetParameterFloat " + parameter); }
        }
        public void SetString(string parameter, string value)
        {
            ValidateParameter(parameter);
            if (value == null || value.IndexOf('\0') >= 0 || value.Length > 511)
                throw new ArgumentException("Value must contain at most 511 characters and no embedded NUL.", "value");
            lock (gate) { EnsureLoggedIn(); Check(setString(parameter, value), "SetParameterStringW " + parameter); }
        }
        public void Dispose()
        {
            lock (gate)
            {
                if (library == null || library.IsClosed) return;
                try
                {
                    if (loggedIn) Check(logout(), "Logout during Dispose");
                }
                finally { loggedIn = false; library.Dispose(); }
            }
        }
        private void EnsureOpen()
        {
            if (library == null || library.IsClosed || library.IsInvalid) throw new ObjectDisposedException("VoicemeeterRemote");
        }
        private void EnsureLoggedIn()
        {
            EnsureOpen();
            if (!loggedIn) throw new InvalidOperationException("Call Login before accessing Voicemeeter parameters.");
        }
        private static void ValidateParameter(string parameter)
        {
            if (String.IsNullOrWhiteSpace(parameter)) throw new ArgumentException("A parameter name is required.", "parameter");
            foreach (char character in parameter)
                if (character < 32 || character > 126) throw new ArgumentException("Parameter names must use printable ASCII.", "parameter");
        }
        private int Check(int result, string operation)
        {
            // Delegates contain native addresses, not a managed reference to the
            // loaded module. Keep it alive until each native call has returned.
            GC.KeepAlive(library);
            if (result < 0) throw new InvalidOperationException("Voicemeeter " + operation + " failed with code " + result + ".");
            return result;
        }
        private T Bind<T>(string name) where T : class
        {
            IntPtr address = GetProcAddress(library, name);
            if (address == IntPtr.Zero) throw new EntryPointNotFoundException("Voicemeeter Remote DLL does not export " + name + ".");
            return (T)(object)Marshal.GetDelegateForFunctionPointer(address, typeof(T));
        }

        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int NoArgs();
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetInt(out int value);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetFloatValue([MarshalAs(UnmanagedType.LPStr)] string parameter, out float value);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int SetFloatValue([MarshalAs(UnmanagedType.LPStr)] string parameter, float value);
        [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet = CharSet.Unicode)]
        private delegate int GetStringValue([MarshalAs(UnmanagedType.LPStr)] string parameter, [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value);
        [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet = CharSet.Unicode)]
        private delegate int SetStringValue([MarshalAs(UnmanagedType.LPStr)] string parameter, [MarshalAs(UnmanagedType.LPWStr)] string value);

        private sealed class LibraryHandle : SafeHandleZeroOrMinusOneIsInvalid
        {
            private LibraryHandle() : base(true) { }
            protected override bool ReleaseHandle() { return FreeLibrary(handle); }
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "LoadLibraryExW", ExactSpelling = true)]
        private static extern LibraryHandle LoadLibraryEx(string fileName, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true, SetLastError = true)]
        private static extern IntPtr GetProcAddress(LibraryHandle module, string name);
        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FreeLibrary(IntPtr module);
    }
}
