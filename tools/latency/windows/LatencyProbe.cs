using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

// SPDX-License-Identifier: MIT
// Same-QPC latency probes for LAN Audio Bridge (Windows). All timings use one clock:
//  Run         render submit -> WASAPI loopback of the same endpoint
//  RunVban     render submit -> vban-sender -> VBAN datagram on 127.0.0.1
//  RunAcoustic render submit -> sender -> NAS -> speaker -> microphone (capture QPC timestamps)
// Audio stays in memory; only timing is reported (DumpPath optionally writes a 1 ms RMS envelope).
public static class LatencyProbe {
 static double Now(){return Stopwatch.GetTimestamp()*1000.0/Stopwatch.Frequency;}
 static void Check(int hr){if(hr<0)Marshal.ThrowExceptionForHR(hr);}
 [DllImport("ole32.dll")] static extern int CoCreateInstance(ref Guid c,IntPtr outer,uint ctx,ref Guid i,out IntPtr p);
 [DllImport("ole32.dll")] static extern void CoTaskMemFree(IntPtr p);
 [DllImport("ole32.dll")] static extern int CoInitializeEx(IntPtr reserved,uint flags);
 [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint p);
 [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint p);
 [DllImport("avrt.dll",CharSet=CharSet.Unicode)] static extern IntPtr AvSetMmThreadCharacteristics(string task,out uint idx);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DGetDevice(IntPtr self,[MarshalAs(UnmanagedType.LPWStr)] string id,out IntPtr p);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DActivate(IntPtr self,ref Guid iid,uint ctx,IntPtr args,out IntPtr p);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DFormat(IntPtr self,out IntPtr p);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DInit(IntPtr self,uint flags,uint n,IntPtr f,IntPtr session);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DInitLegacy(IntPtr self,int share,uint flags,long duration,long period,IntPtr f,IntPtr session);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DCapture(IntPtr self,out IntPtr p,out uint frames,out uint flags,out ulong devicePos,out ulong qpc);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DCaptureRelease(IntPtr self,uint frames);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DUInt(IntPtr self,out uint n);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DSimple(IntPtr self);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DEvent(IntPtr self,IntPtr h);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DService(IntPtr self,ref Guid iid,out IntPtr p);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DBuffer(IntPtr self,uint n,out IntPtr p);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DRelease(IntPtr self,uint n,uint flags);
 static T Fn<T>(IntPtr p,int n){return (T)(object)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(Marshal.ReadIntPtr(p),n*IntPtr.Size),typeof(T));}
 static void Rel(IntPtr p){if(p!=IntPtr.Zero)Marshal.Release(p);}
 static IntPtr Open(string id){IntPtr e=IntPtr.Zero,d=IntPtr.Zero,a=IntPtr.Zero;Guid cl=new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"),ie=new Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),ia=new Guid("7ED4EE07-8E67-4CD4-8C1A-2B7A5987AD42");try{Check(CoCreateInstance(ref cl,IntPtr.Zero,23,ref ie,out e));Check(Fn<DGetDevice>(e,5)(e,id,out d));Check(Fn<DActivate>(d,3)(d,ref ia,23,IntPtr.Zero,out a));return a;}finally{Rel(d);Rel(e);}}


 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DDefault(IntPtr self,int flow,int role,out IntPtr p);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DGetId(IntPtr self,out IntPtr id);
 public static string DefaultCaptureId(){IntPtr e=IntPtr.Zero,d=IntPtr.Zero,id=IntPtr.Zero;Guid cl=new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"),ie=new Guid("A95664D2-9614-4F35-A746-DE8DB63617E6");
  try{Check(CoCreateInstance(ref cl,IntPtr.Zero,23,ref ie,out e));Check(Fn<DDefault>(e,4)(e,1,0,out d));Check(Fn<DGetId>(d,5)(d,out id));return Marshal.PtrToStringUni(id);}
  finally{if(id!=IntPtr.Zero)CoTaskMemFree(id);Rel(d);Rel(e);}}
 public sealed class Mark{public int Index;public double SubmittedMs,CapturedMs,DelayMs,EngineQpcDelayMs,Correlation;}
 public sealed class Result{public string Endpoint,Error,Done;public uint RenderPeriod,RenderBuffer,CaptureBuffer;public double MedianMs,P95Ms,MaxMs,EngineMedianMs,PacketGapP95,PacketGapMax;public int CapturePackets,Discontinuities,Silent;public Dictionary<uint,int> PacketSizes=new Dictionary<uint,int>();public List<Mark> Marks=new List<Mark>();}
 const int Rate=48000,First=9600,Spacing=24000;public static int Count=10;public static int PatternLength=256;public static short Level=6000;
 static short[] Pattern(){var r=new short[PatternLength];uint x=0x17263489;for(int i=0;i<r.Length;i++){x^=x<<13;x^=x>>17;x^=x<<5;r[i]=(short)((x&1)==0?Level:-Level);}return r;}
 public static float Background=0; // e.g. 60/32768: quiet 997 Hz tone keeps the receiver in steady state
 static float Sample(int pos,short[] pat){int k=(pos-First)/Spacing,j=pos-First-k*Spacing;float bg=Background*(float)Math.Sin(2*Math.PI*997*pos/48000.0);return pos>=First&&k<Count&&j<PatternLength?pat[j]/32768f+bg:bg;}
 static double Pct(List<double> d,double p){var s=new List<double>(d);s.Sort();if(s.Count==0)return double.NaN;return s[Math.Max(0,(int)Math.Ceiling(p*s.Count)-1)];}

 // renderPeriod: 0 = legacy Initialize with renderBufferMs; >0 = IAudioClient3 period in frames.
 // keeperPeriod: >0 opens an extra silent IAudioClient3 stream to force a small engine period.
 public static Result Run(string id,uint renderPeriod,int renderBufferMs,bool pollCapture){
  var r=new Result{Endpoint=id};short[] pat=Pattern();
  var samples=new List<float>(Rate*8);var times=new List<double>(Rate*8);var engine=new List<double>(Rate*8);var gaps=new List<double>();
  bool stop=false;Exception capErr=null;var ready=new ManualResetEvent(false);
  timeBeginPeriod(1);
  var cap=new Thread(delegate(){IntPtr a=IntPtr.Zero,f=IntPtr.Zero,cc=IntPtr.Zero;bool started=false;CoInitializeEx(IntPtr.Zero,0);uint ix;AvSetMmThreadCharacteristics("Pro Audio",out ix);
   using(var ev=new AutoResetEvent(false)){try{
    a=Open(id);Check(Fn<DFormat>(a,8)(a,out f));
    uint flags=0x20000u|(pollCapture?0u:0x40000u);
    Check(Fn<DInitLegacy>(a,3)(a,0,flags,pollCapture?200000:0,0,f,IntPtr.Zero));
    if(!pollCapture)Check(Fn<DEvent>(a,13)(a,ev.SafeWaitHandle.DangerousGetHandle()));
    uint sz;Check(Fn<DUInt>(a,4)(a,out sz));r.CaptureBuffer=sz;
    Guid ic=new Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317");Check(Fn<DService>(a,14)(a,ref ic,out cc));Check(Fn<DSimple>(a,10)(a));started=true;ready.Set();double last=0;
    while(!Volatile.Read(ref stop)){
     if(pollCapture)Thread.Sleep(1);else if(!ev.WaitOne(100))continue;
     uint next;Check(Fn<DUInt>(cc,5)(cc,out next));
     while(next>0){IntPtr data;uint n,fl;ulong pos,qpc;Check(Fn<DCapture>(cc,3)(cc,out data,out n,out fl,out pos,out qpc));double t=Now();
      r.CapturePackets++;if((fl&1)!=0)r.Discontinuities++;if((fl&2)!=0)r.Silent++;int c;r.PacketSizes.TryGetValue(n,out c);r.PacketSizes[n]=c+1;if(last>0)gaps.Add(t-last);last=t;
      float[] v=new float[n*2];if((fl&2)==0)Marshal.Copy(data,v,0,v.Length);
      double q=qpc/10000.0;for(int j=0;j<n;j++){samples.Add(v[2*j]);times.Add(t);engine.Add(q+j/48.0);}
      Check(Fn<DCaptureRelease>(cc,4)(cc,n));Check(Fn<DUInt>(cc,5)(cc,out next));}
    }}catch(Exception e){capErr=e;ready.Set();}finally{if(started)Fn<DSimple>(a,11)(a);Rel(cc);if(f!=IntPtr.Zero)CoTaskMemFree(f);Rel(a);}}});
  cap.Start();
  try{
   if(!ready.WaitOne(5000))throw new Exception("capture not ready");if(capErr!=null)throw capErr;Thread.Sleep(300);
   Play(r,id,renderPeriod,renderBufferMs,pat);Thread.Sleep(300);
  }catch(Exception e){r.Error=e.ToString();}finally{Volatile.Write(ref stop,true);cap.Join(3000);timeEndPeriod(1);}
  if(capErr!=null)r.Error=(r.Error??"")+capErr.ToString();
  double norm=0;foreach(short x in pat)norm+=(double)x*x;var d=new List<double>();var de=new List<double>();
  float[] s=samples.ToArray();
  foreach(var m in r.Marks){double best=0;int found=-1;for(int i=0;i+PatternLength<s.Length;i++){double dt=times[i]-m.SubmittedMs;if(dt<-5||dt>500)continue;double dot=0,en=0;for(int j=0;j<PatternLength;j++){double v=s[i+j]*32768.0;dot+=v*pat[j];en+=v*v;}double corr=en>0?dot/Math.Sqrt(norm*en):0;if(corr>best){best=corr;found=i;}}
   m.Correlation=best;if(found>=0&&best>0.8){m.CapturedMs=times[found];m.DelayMs=m.CapturedMs-m.SubmittedMs;m.EngineQpcDelayMs=engine[found]-m.SubmittedMs;d.Add(m.DelayMs);de.Add(m.EngineQpcDelayMs);}}
  r.MedianMs=Pct(d,.5);r.P95Ms=Pct(d,.95);r.MaxMs=Pct(d,1);r.EngineMedianMs=Pct(de,.5);r.PacketGapP95=Pct(gaps,.95);r.PacketGapMax=Pct(gaps,1);
  if(d.Count!=Count)r.Error=(r.Error??"")+" markers found "+d.Count;
  return r;
 }
 public static int MaxFill=0; // >0: keep at most this many frames queued (low-latency app)
 // Plays markers to `id` while the real sender targets 127.0.0.1:port; timestamps marker onsets in received VBAN.
 public static Result RunVban(string id,uint renderPeriod,int renderBufferMs,int port,int threshold){
  var r=new Result{Endpoint=id};short[] pat=Pattern();var onsets=new List<double>();bool stop=false;Exception rxErr=null;long quiet=7200;
  using(var udp=new System.Net.Sockets.UdpClient(new System.Net.IPEndPoint(System.Net.IPAddress.Loopback,port))){
   udp.Client.ReceiveTimeout=200;
   var rx=new Thread(delegate(){uint ix;AvSetMmThreadCharacteristics("Pro Audio",out ix);try{while(!Volatile.Read(ref stop)){try{var e2=new System.Net.IPEndPoint(System.Net.IPAddress.Any,0);byte[] d=udp.Receive(ref e2);double t=Now();if(d.Length<28)continue;int n=(d.Length-28)/4;for(int j=0;j<n;j++){short v=BitConverter.ToInt16(d,28+j*4);if(Math.Abs((int)v)>threshold){if(quiet>=7200)lock(onsets)onsets.Add(t);quiet=0;}else quiet++;}}catch(System.Net.Sockets.SocketException ex){if(ex.SocketErrorCode!=System.Net.Sockets.SocketError.TimedOut)throw;}}}catch(Exception ex){rxErr=ex;}});
   rx.Start();
   try{Thread.Sleep(300);Play(r,id,renderPeriod,renderBufferMs,pat);Thread.Sleep(300);}catch(Exception e){r.Error=e.ToString();}finally{Volatile.Write(ref stop,true);rx.Join(2000);}
  }
  if(rxErr!=null)r.Error=(r.Error??"")+rxErr.ToString();
  var d2=new List<double>();
  foreach(var m in r.Marks){double best=double.NaN;lock(onsets)foreach(var t in onsets){double dt=t-m.SubmittedMs;if(dt>-2&&dt<400&&(double.IsNaN(best)||dt<best))best=dt;}if(!double.IsNaN(best)){m.DelayMs=best;d2.Add(best);}}
  r.CapturePackets=onsets.Count;r.MedianMs=Pct(d2,.5);r.P95Ms=Pct(d2,.95);r.MaxMs=Pct(d2,1);r.EngineMedianMs=Pct(d2,0.0001);
  if(d2.Count!=Count)r.Error=(r.Error??"")+" markers "+d2.Count+" onsets "+onsets.Count;
  return r;
 }
 // Acoustic end-to-end: markers -> render endpoint -> sender -> NAS -> speaker -> microphone (same QPC clock).
 // Onset = first mic sample above K x the pre-marker noise RMS. Time uses the capture packet's QPC device
 // timestamp (excludes microphone buffering) and, separately, packet arrival time (includes it).
 public sealed class Acoustic{public string Error;public uint MicRate,MicChannels,MicBuffer;public int TimestampErrors,Discontinuities;public List<double> QpcDelays=new List<double>(),ArrivalDelays=new List<double>();public List<double> Snr=new List<double>();}
 public static string DumpPath=null;
 public static Acoustic RunAcoustic(string renderId,string micId,uint period,double k){
  var a=new Acoustic();short[] pat=Pattern();var r=new Result();var x=new List<float>(Rate*40);var tq=new List<double>(Rate*40);var ta=new List<double>(Rate*40);
  bool stop=false;Exception capErr=null;var ready=new ManualResetEvent(false);uint micRate=48000;
  var cap=new Thread(delegate(){IntPtr ac=IntPtr.Zero,f=IntPtr.Zero,cc=IntPtr.Zero;bool started=false;CoInitializeEx(IntPtr.Zero,0);uint ix;AvSetMmThreadCharacteristics("Pro Audio",out ix);
   using(var ev=new AutoResetEvent(false)){try{
    ac=Open(micId);Check(Fn<DFormat>(ac,8)(ac,out f));micRate=(uint)Marshal.ReadInt32(f,4);int ch=Marshal.ReadInt16(f,2);a.MicRate=micRate;a.MicChannels=(uint)ch;
    bool isFloat=Marshal.ReadInt16(f,14)==32;
    Check(Fn<DInitLegacy>(ac,3)(ac,0,0x40000,0,0,f,IntPtr.Zero));Check(Fn<DEvent>(ac,13)(ac,ev.SafeWaitHandle.DangerousGetHandle()));
    uint sz;Check(Fn<DUInt>(ac,4)(ac,out sz));a.MicBuffer=sz;
    Guid ic=new Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317");Check(Fn<DService>(ac,14)(ac,ref ic,out cc));Check(Fn<DSimple>(ac,10)(ac));started=true;ready.Set();
    while(!Volatile.Read(ref stop)){if(!ev.WaitOne(100))continue;uint next;Check(Fn<DUInt>(cc,5)(cc,out next));
     while(next>0){IntPtr data;uint n,fl;ulong pos,qpc;Check(Fn<DCapture>(cc,3)(cc,out data,out n,out fl,out pos,out qpc));double t=Now();
      if((fl&1)!=0)a.Discontinuities++;if((fl&4)!=0)a.TimestampErrors++;
      float[] v=new float[n*ch];if((fl&2)==0){if(isFloat)Marshal.Copy(data,v,0,v.Length);else{short[] s=new short[n*ch];Marshal.Copy(data,s,0,s.Length);for(int i=0;i<s.Length;i++)v[i]=s[i]/32768f;}}
      double q=qpc*1000.0/1e7;for(int j=0;j<n;j++){x.Add(v[j*ch]);tq.Add(q+j*1000.0/micRate);ta.Add(t);}
      Check(Fn<DCaptureRelease>(cc,4)(cc,n));Check(Fn<DUInt>(cc,5)(cc,out next));}
    }}catch(Exception e){capErr=e;ready.Set();}finally{if(started)Fn<DSimple>(ac,11)(ac);Rel(cc);if(f!=IntPtr.Zero)CoTaskMemFree(f);Rel(ac);}}});
  cap.Start();
  try{if(!ready.WaitOne(5000))throw new Exception("mic not ready");if(capErr!=null)throw capErr;Thread.Sleep(500);
   Play(r,renderId,period,10,pat);Thread.Sleep(800);}catch(Exception e){a.Error=e.ToString();}finally{Volatile.Write(ref stop,true);cap.Join(3000);}
  if(capErr!=null)a.Error=(a.Error??"")+capErr;
  // Capture qpcPosition is in 100 ns QPC units, the same epoch as Now() (Stopwatch ticks).
  float[] s2=x.ToArray();
  foreach(var m in r.Marks){
   int i0=ta.BinarySearch(m.SubmittedMs);if(i0<0)i0=~i0;int nb=(int)(micRate*0.06);if(i0-nb<0||i0>=s2.Length)continue;
   double e=0;for(int i=i0-nb;i<i0;i++)e+=s2[i]*s2[i];double rms=Math.Sqrt(e/nb)+1e-6;
   int hit=-1;double peak=0;int end=Math.Min(s2.Length,i0+(int)(micRate*0.3));
   int run=0;for(int i=i0;i<end;i++){if(Math.Abs(s2[i])>k*rms){if(++run>=3){hit=i-2;break;}}else run=0;}
   if(hit<0)continue;for(int i=hit;i<Math.Min(end,hit+(int)(micRate*0.01));i++)peak=Math.Max(peak,Math.Abs(s2[i]));
   a.QpcDelays.Add(tq[hit]-m.SubmittedMs);a.ArrivalDelays.Add(ta[hit]-m.SubmittedMs);a.Snr.Add(20*Math.Log10(peak/rms));}
  if(DumpPath!=null){using(var w=new System.IO.StreamWriter(DumpPath)){foreach(var m in r.Marks){int i0=ta.BinarySearch(m.SubmittedMs);if(i0<0)i0=~i0;
    // 1 ms RMS envelope from -50 ms to +450 ms around submit, QPC-referenced
    var sb=new System.Text.StringBuilder();sb.Append(m.Index);for(int b=-50;b<450;b++){int st=i0+b*(int)(micRate/1000);double e=0;int c=0;for(int i=st;i<st+micRate/1000&&i>=0&&i<s2.Length;i++){e+=s2[i]*s2[i];c++;}sb.Append(',').Append(c>0?Math.Sqrt(e/c).ToString("G4"):"0");}
    sb.Append(";").Append((tq[Math.Min(i0,tq.Count-1)]-m.SubmittedMs).ToString("F3"));w.WriteLine(sb.ToString());}}}
  if(a.QpcDelays.Count!=Count)a.Error=(a.Error??"")+" detected "+a.QpcDelays.Count+"/"+Count;
  return a;
 }
 // "Submit" = the moment the marker frame is released to WASAPI. Frames already queued (padding) play before it,
 // so the measured delay includes the application's own render queue, as for a real player.
 static void Play(Result r,string id,uint period,int bufferMs,short[] pat){
  IntPtr a=Open(id),f=IntPtr.Zero,rc=IntPtr.Zero;bool started=false;uint ix;AvSetMmThreadCharacteristics("Pro Audio",out ix);
  using(var ev=new AutoResetEvent(false)){try{
   Check(Fn<DFormat>(a,8)(a,out f));
   if(period>0)Check(Fn<DInit>(a,20)(a,0x40000,period,f,IntPtr.Zero));else Check(Fn<DInitLegacy>(a,3)(a,0,0x40000,bufferMs*10000L,0,f,IntPtr.Zero));
   Check(Fn<DEvent>(a,13)(a,ev.SafeWaitHandle.DangerousGetHandle()));
   uint buffer;Check(Fn<DUInt>(a,4)(a,out buffer));r.RenderBuffer=buffer;r.RenderPeriod=period;
   Guid ir=new Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2");Check(Fn<DService>(a,14)(a,ref ir,out rc));
   IntPtr p;Check(Fn<DBuffer>(rc,3)(rc,buffer,out p));Check(Fn<DRelease>(rc,4)(rc,buffer,2));int pos=0;
   Check(Fn<DSimple>(a,10)(a));started=true;int total=First+Count*Spacing+4800;
   while(pos<total){if(!ev.WaitOne(1000))throw new Exception("render timeout");uint pad;Check(Fn<DUInt>(a,6)(a,out pad));int n=(int)((MaxFill>0?Math.Min((uint)MaxFill,buffer):buffer)-pad);if(n<=0)continue;
    Check(Fn<DBuffer>(rc,3)(rc,(uint)n,out p));float[] v=new float[n*2];for(int j=0;j<n;j++)v[2*j]=v[2*j+1]=Sample(pos+j,pat);Marshal.Copy(v,0,p,v.Length);
    double submit=Now();
    for(int k=0;k<Count;k++){int t=First+k*Spacing;if(t>=pos&&t<pos+n)r.Marks.Add(new Mark{Index=k,SubmittedMs=submit});}
    Check(Fn<DRelease>(rc,4)(rc,(uint)n,0));pos+=n;}
  }finally{if(started)Fn<DSimple>(a,11)(a);Rel(rc);if(f!=IntPtr.Zero)CoTaskMemFree(f);Rel(a);}}
 }
}
