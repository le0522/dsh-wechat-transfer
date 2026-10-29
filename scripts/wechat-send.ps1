<#
  wechat-send.ps1 - send files to a WeChat 4.x chat window (default: 文件传输助手)
  Safe by design: it never closes/hides windows, never presses Escape, never kills WeChat,
  and it only pastes after the chat header has been verified by OCR.
  When WeChat is not running it starts it, and it clicks 「进入微信」 when the login window
  offers that button; a QR-only login is reported, never guessed.
  Output: one JSON object on stdout. Exit code 0 on success, non-zero on failure.
#>
[CmdletBinding()]
param(
  [string] $Job,
  [string[]] $Paths,
  [string] $Chat,
  [switch] $AutoSend,
  [string] $ScreenshotOut,
  [string] $LogOut,
  [int] $WindowWaitSeconds = 15,
  [switch] $LoginOnly
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$script:log = New-Object System.Collections.Generic.List[string]
$script:stages = New-Object System.Collections.Generic.List[string]
# set when this run resized the WeChat window, restored from the finally block
$script:restoreRect = $null
$script:restoreHandle = [IntPtr]::Zero

function Restore-WeChatWindow {
  if (-not $script:restoreRect) { return }
  $saved = $script:restoreRect
  $handle = $script:restoreHandle
  $script:restoreRect = $null
  try {
    [void][Wx]::SetWindowPos($handle, [IntPtr]::Zero, $saved.x, $saved.y, $saved.w, $saved.h, 0x0004)
    Add-Log "window put back to $($saved.w)x$($saved.h) at $($saved.x),$($saved.y)"
  } catch {
    Add-Log "window restore failed: $($_.Exception.Message)"
  }
}

function Add-Log([string] $message) {
  $stamp = (Get-Date).ToString('HH:mm:ss.fff')
  $script:log.Add("$stamp $message") | Out-Null
}
function Enter-Stage([string] $name) {
  $script:stages.Add($name) | Out-Null
  Add-Log "[$name]"
}
function Write-Result($result) {
  # always attach the diagnostics, including on the early-exit (failure) paths
  $result.stages = $script:stages.ToArray()
  $result.log = $script:log.ToArray()
  $json = $result | ConvertTo-Json -Depth 8 -Compress
  if ($LogOut) {
    try { [System.IO.File]::WriteAllLines($LogOut, $script:log, (New-Object System.Text.UTF8Encoding($false))) } catch { }
  }
  [Console]::Out.Write($json)
  [Console]::Out.Flush()
}

# ---------------------------------------------------------------- interop
$interopSource = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public class Wx {

  public delegate bool EnumProc(IntPtr h, IntPtr l);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);

  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SetActiveWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

  [StructLayout(LayoutKind.Sequential)]
  public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)]
  public struct INPUT { public uint type; public MOUSEINPUT mi; }

  [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);

  [DllImport("user32.dll")] public static extern IntPtr OpenClipboard(IntPtr owner);
  [DllImport("user32.dll")] public static extern bool CloseClipboard();
  [DllImport("user32.dll")] public static extern bool EmptyClipboard();
  [DllImport("user32.dll")] public static extern IntPtr SetClipboardData(uint format, IntPtr data);
  [DllImport("kernel32.dll")] public static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
  [DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr mem);
  [DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr mem);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);





  /// Finds the native "选择文件" / Open dialog that WeChat shows for its folder button.
  public static IntPtr FindDialog() {
    IntPtr best = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      StringBuilder cb = new StringBuilder(256); GetClassName(h, cb, 256);
      StringBuilder tb = new StringBuilder(512); GetWindowText(h, tb, 512);
      string cls = cb.ToString(); string title = tb.ToString();
      RECT r; GetWindowRect(h, out r);
      int w = r.Right - r.Left; int hgt = r.Bottom - r.Top;
      if (w < 320 || hgt < 200) return true;
      bool isDialogClass = cls == "#32770";
      bool isOpenTitle = title == "选择文件" || title == "打开" || title == "Open" || title == "Select File" || title.Contains("打开");
      if (isDialogClass || isOpenTitle) {
        if (title.Contains("搜索聊天记录") || title.Contains("微信")) return true;
        best = h;
        return false;
      }
      return true;
    }, IntPtr.Zero);
    return best;
  }

  public static void SetClipboardText(string text) {
    IntPtr block = GlobalAlloc(0x0042, (UIntPtr)((text.Length + 1) * 2));
    IntPtr ptr = GlobalLock(block);
    Marshal.Copy(Encoding.Unicode.GetBytes(text + "\0"), 0, ptr, (text.Length + 1) * 2);
    GlobalUnlock(block);
    if (OpenClipboard(IntPtr.Zero) == IntPtr.Zero) { throw new Exception("OpenClipboard failed"); }
    try {
      EmptyClipboard();
      if (SetClipboardData(13, block) == IntPtr.Zero) { throw new Exception("SetClipboardData(CF_UNICODETEXT) failed"); }
    } finally { CloseClipboard(); }
  }

  static Wx() { try { SetProcessDPIAware(); } catch { } }

  /// Largest Qt window belonging to WeChat (tray windows excluded).
  public static IntPtr FindMain() {
    IntPtr best = IntPtr.Zero; int bestArea = 0;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == 0) return true;
      string pname;
      try { pname = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { return true; }
      if (!(pname.Equals("Weixin") || pname.Equals("WeChat"))) return true;
      StringBuilder cb = new StringBuilder(256); GetClassName(h, cb, 256);
      string cls = cb.ToString();
      if (!cls.StartsWith("Qt")) return true;
      if (cls.IndexOf("Tray", StringComparison.OrdinalIgnoreCase) >= 0) return true;
      RECT r; GetWindowRect(h, out r);
      int area = (r.Right - r.Left) * (r.Bottom - r.Top);
      if (area > bestArea) { bestArea = area; best = h; }
      return true;
    }, IntPtr.Zero);
    return best;
  }

  public static string Title(IntPtr h) {
    StringBuilder sb = new StringBuilder(512);
    GetWindowText(h, sb, 512);
    return sb.ToString();
  }

  /// Raise a window without leaving modifier keys stuck.
  public static bool Focus(IntPtr h) {
    ShowWindow(h, 9);
    uint pid; uint fgThread = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
    uint myThread = GetCurrentThreadId();
    bool attached = false;
    if (fgThread != myThread && fgThread != 0) attached = AttachThreadInput(myThread, fgThread, true);
    BringWindowToTop(h);
    SetForegroundWindow(h);
    SetFocus(h);
    SetActiveWindow(h);
    if (attached) AttachThreadInput(myThread, fgThread, false);
    System.Threading.Thread.Sleep(120);
    return GetForegroundWindow() == h;
  }

  public static void ClickInput(int x, int y) {
    int sw = GetSystemMetrics(0);
    int sh = GetSystemMetrics(1);
    int ax = (int)Math.Round(x * 65535.0 / Math.Max(1, sw - 1));
    int ay = (int)Math.Round(y * 65535.0 / Math.Max(1, sh - 1));
    INPUT[] inputs = new INPUT[3];
    inputs[0].type = 0; inputs[0].mi.dx = ax; inputs[0].mi.dy = ay; inputs[0].mi.dwFlags = 0x0001 | 0x8000;
    inputs[1].type = 0; inputs[1].mi.dx = ax; inputs[1].mi.dy = ay; inputs[1].mi.dwFlags = 0x0002;
    inputs[2].type = 0; inputs[2].mi.dx = ax; inputs[2].mi.dy = ay; inputs[2].mi.dwFlags = 0x0004;
    SendInput(3, inputs, Marshal.SizeOf(typeof(INPUT)));
  }

  /// Mouse wheel over a point; delta is in wheel units (120 = one notch).
  public static void Wheel(int x, int y, int delta) {
    int sw = GetSystemMetrics(0);
    int sh = GetSystemMetrics(1);
    int ax = (int)Math.Round(x * 65535.0 / Math.Max(1, sw - 1));
    int ay = (int)Math.Round(y * 65535.0 / Math.Max(1, sh - 1));
    INPUT[] inputs = new INPUT[1];
    inputs[0].type = 0; inputs[0].mi.dx = ax; inputs[0].mi.dy = ay;
    inputs[0].mi.mouseData = (uint)delta;
    inputs[0].mi.dwFlags = 0x0001 | 0x8000 | 0x0800;
    SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT)));
  }

  public static void CtrlV() {
    keybd_event(0x11, 0, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(40);
    keybd_event(0x56, 0, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(40);
    keybd_event(0x56, 0, 2, UIntPtr.Zero);
    System.Threading.Thread.Sleep(40);
    keybd_event(0x11, 0, 2, UIntPtr.Zero);
  }

  public static void Enter() {
    keybd_event(0x0D, 0, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(40);
    keybd_event(0x0D, 0, 2, UIntPtr.Zero);
  }

  /// Puts real CF_HDROP data on the clipboard; the block survives this process.
  public static void SetFileDrop(string[] paths) {
    int bytes = 20 + 2;
    foreach (string path in paths) { bytes += (path.Length + 1) * 2; }
    IntPtr block = GlobalAlloc(0x0042, (UIntPtr)bytes);
    IntPtr ptr = GlobalLock(block);
    byte[] buffer = new byte[bytes];
    BitConverter.GetBytes(20).CopyTo(buffer, 0);
    BitConverter.GetBytes(1).CopyTo(buffer, 16);
    int offset = 20;
    foreach (string path in paths) {
      byte[] chars = Encoding.Unicode.GetBytes(path);
      chars.CopyTo(buffer, offset);
      offset += chars.Length + 2;
    }
    Marshal.Copy(buffer, 0, ptr, bytes);
    GlobalUnlock(block);
    if (OpenClipboard(IntPtr.Zero) == IntPtr.Zero) { throw new Exception("OpenClipboard failed"); }
    try {
      EmptyClipboard();
      if (SetClipboardData(15, block) == IntPtr.Zero) { throw new Exception("SetClipboardData(CF_HDROP) failed"); }
    } finally { CloseClipboard(); }
  }
}
'@

Add-Type -TypeDefinition $interopSource -Language CSharp | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null
Add-Type -AssemblyName System.Windows.Forms | Out-Null

# ---------------------------------------------------------------- OCR (Windows.Media.Ocr)
$script:ocrOk = $false
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
  $script:asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
      $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

  function Await($operation, [Type] $resultType) {
    $asTask = $script:asTaskGeneric.MakeGenericMethod($resultType)
    $task = $asTask.Invoke($null, @($operation))
    [void] $task.Wait(-1)
    $task.Result
  }

  [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
  [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
  [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null

  $script:ocrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  if ($null -eq $script:ocrEngine) { throw 'no OCR engine for the user profile languages' }

  function Get-OcrLines($bitmap) {
    $ms = New-Object System.IO.MemoryStream
    $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $ms.ToArray(); $ms.Dispose()
    $stream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
    $writer = New-Object Windows.Storage.Streams.DataWriter($stream.GetOutputStreamAt(0))
    $writer.WriteBytes($bytes)
    [void] (Await ($writer.StoreAsync()) ([uint32]))
    [void] (Await ($writer.FlushAsync()) ([bool]))
    $writer.DetachStream() | Out-Null
    $stream.Seek(0)
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $softwareBitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $text = Await ($script:ocrEngine.RecognizeAsync($softwareBitmap)) ([Windows.Media.Ocr.OcrResult])
    $lines = @()
    foreach ($line in $text.Lines) {
      $minX = [double]::MaxValue; $minY = [double]::MaxValue; $maxX = 0.0; $maxY = 0.0
      foreach ($word in $line.Words) {
        $b = $word.BoundingRect
        if ($b.X -lt $minX) { $minX = $b.X }
        if ($b.Y -lt $minY) { $minY = $b.Y }
        if (($b.X + $b.Width) -gt $maxX) { $maxX = $b.X + $b.Width }
        if (($b.Y + $b.Height) -gt $maxY) { $maxY = $b.Y + $b.Height }
      }
      if ($line.Words.Count -gt 0) {
        $lines += [pscustomobject]@{ text = $line.Text; x = $minX; y = $minY; w = ($maxX - $minX); h = ($maxY - $minY) }
      }
    }
    return $lines
  }

  function Get-OcrCrop($bitmap, [double] $left, [double] $top, [double] $width, [double] $height) {
    $x = [int]($bitmap.Width * $left)
    $y = [int]($bitmap.Height * $top)
    $w = [int]($bitmap.Width * $width)
    $h = [int]($bitmap.Height * $height)
    if ($w -lt 4 -or $h -lt 4) { return @() }
    $crop = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($crop)
    $g.DrawImage($bitmap, (New-Object System.Drawing.Rectangle 0, 0, $w, $h), (New-Object System.Drawing.Rectangle $x, $y, $w, $h), [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    try { return Get-OcrLines $crop } finally { $crop.Dispose() }
  }

  $script:ocrOk = $true
} catch {
  Add-Log "ocr-unavailable: $($_.Exception.Message)"
}

function Get-WindowBitmap([IntPtr] $handle) {
  $rect = New-Object Wx+RECT
  if (-not [Wx]::GetWindowRect($handle, [ref] $rect)) { throw 'GetWindowRect failed' }
  $w = $rect.Right - $rect.Left
  $h = $rect.Bottom - $rect.Top
  if ($w -lt 100 -or $h -lt 100) { throw "window too small (${w}x${h})" }
  [void][Wx]::Focus($handle)
  Start-Sleep -Milliseconds 200
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
  $g.Dispose()
  return @{ bitmap = $bmp; rect = $rect }
}

function Get-WindowOcr([IntPtr] $handle, [double] $left, [double] $top, [double] $width, [double] $height) {
  $shot = Get-WindowBitmap $handle
  try {
    if (-not $script:ocrOk) { return '' }
    $lines = Get-OcrCrop $shot.bitmap $left $top $width $height
    return (($lines | ForEach-Object { $_.text -replace '\s+', '' }) -join '|')
  } finally { $shot.bitmap.Dispose() }
}

# File cards in the composer truncate long names ("季度报告_终稿...版.docx"), so a literal or
# coverage match can never succeed for long names. Verify by the signals the card keeps:
#   * the "340K" size label under the card (most stable, and we know the real size)
#   * the first 6 characters of the name plus the extension / last 4 characters
#   * the full normalised name (short names only)
function Get-NameKey([string] $value) {
  if (-not $value) { return '' }
  return ($value -replace '[^0-9A-Za-z\u4e00-\u9fff]', '').ToLowerInvariant()
}

function Get-SizeToken([long] $bytes) {
  if ($bytes -ge 1048576) { return ('{0:0.0}M' -f ($bytes / 1048576.0)) }
  return ('{0:0.0}K' -f ($bytes / 1024.0))
}

function Test-FileCard([string] $ocrText, [string] $path) {
  if (-not $ocrText -or -not $path) { return $false }
  $haystack = Get-NameKey $ocrText
  $stem = [System.IO.Path]::GetFileNameWithoutExtension($path)
  $key = Get-NameKey $stem
  $extKey = Get-NameKey ([System.IO.Path]::GetExtension($path))
  if ($key.Length -eq 0) { return $false }

  # 1) size label
  try {
    $sizeToken = Get-NameKey (Get-SizeToken (Get-Item -LiteralPath $path).Length)
    if ($sizeToken -and $haystack.Contains($sizeToken)) { return $true }
  } catch { }

  # 2) truncated card: head of the name plus the extension (or the tail of the name)
  $head = if ($key.Length -ge 6) { $key.Substring(0, 6) } else { $key }
  $headHit = $haystack.Contains($head)
  $tailHit = $false
  if ($key.Length -ge 4) { $tailHit = $haystack.Contains($key.Substring($key.Length - 4)) }
  $extHit = $extKey -and $haystack.Contains($extKey)
  if ($headHit -and ($tailHit -or $extHit)) { return $true }

  # 3) short names that fit on the card
  return $haystack.Contains($key)
}

function Test-AnyFileCard([string] $ocrText, [string[]] $paths) {
  $seen = 0
  foreach ($path in $paths) { if (Test-FileCard $ocrText $path) { $seen++ } }
  return $seen
}

# --- structural check -------------------------------------------------------
# Image files render as a thumbnail card with no file name and no size label, so OCR cannot
# recognise them. These helpers compare the composer region against the empty state captured
# before the dialog opened: a meaningful pixel change means something was really added.
function Get-RegionGrid([System.Drawing.Bitmap] $bitmap, [double] $left, [double] $top, [double] $width, [double] $height) {
  $cols = 16
  $rows = 8
  $grid = New-Object 'int[]' ($cols * $rows)
  $l = [int]($bitmap.Width * $left)
  $t = [int]($bitmap.Height * $top)
  $w = [int]($bitmap.Width * $width)
  $h = [int]($bitmap.Height * $height)
  for ($r = 0; $r -lt $rows; $r++) {
    for ($c = 0; $c -lt $cols; $c++) {
      $sum = 0
      $n = 0
      for ($dy = 0; $dy -lt 4; $dy++) {
        for ($dx = 0; $dx -lt 4; $dx++) {
          $x = $l + [int](($c + ($dx + 0.5) / 4) * $w / $cols)
          $y = $t + [int](($r + ($dy + 0.5) / 4) * $h / $rows)
          if ($x -ge 0 -and $y -ge 0 -and $x -lt $bitmap.Width -and $y -lt $bitmap.Height) {
            $p = $bitmap.GetPixel($x, $y)
            $sum += [int](($p.R + $p.G + $p.B) / 3)
            $n++
          }
        }
      }
      $grid[($r * $cols) + $c] = if ($n -gt 0) { [int]($sum / $n) } else { 255 }
    }
  }
  return , $grid
}

function Get-ComposerGrid([IntPtr] $handle) {
  $shot = Get-WindowBitmap $handle
  try {
    return Get-RegionGrid $shot.bitmap 0.44 0.60 0.55 0.35
  } finally {
    $shot.bitmap.Dispose()
  }
}

function Test-GridChanged($before, $after, [int] $threshold = 14, [double] $minRatio = 0.06) {
  if ($null -eq $before -or $null -eq $after) { return $false }
  if ($before.Count -ne $after.Count) { return $false }
  $diff = 0
  for ($i = 0; $i -lt $before.Count; $i++) {
    if ([Math]::Abs($before[$i] - $after[$i]) -ge $threshold) { $diff++ }
  }
  return (($diff / [double]$before.Count) -ge $minRatio)
}

function Get-PaneGrid([IntPtr] $handle) {
  $shot = Get-WindowBitmap $handle
  try {
    return Get-RegionGrid $shot.bitmap 0.44 0.10 0.55 0.50
  } finally {
    $shot.bitmap.Dispose()
  }
}

function Save-WindowShot([IntPtr] $handle, [string] $path) {
  if (-not $path) { return }
  try {
    $shot = Get-WindowBitmap $handle
    try { $shot.bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $shot.bitmap.Dispose() }
  } catch { Add-Log "screenshot failed: $($_.Exception.Message)" }
}

function Get-WeixinExecutable {
  $candidates = @()
  try {
    $reg = Get-ItemProperty -Path 'HKCU:\Software\Tencent\Weixin' -ErrorAction Stop
    if ($reg.InstallPath) { $candidates += (Join-Path $reg.InstallPath 'Weixin.exe') }
  } catch { }
  $candidates += @(
    'C:\Program Files\Tencent\Weixin\Weixin.exe',
    'C:\Program Files (x86)\Tencent\Weixin\Weixin.exe'
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
  }
  return $null
}

function Wait-WeChatWindow([int] $seconds) {
  $until = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $until) {
    $found = [Wx]::FindMain()
    if ($found -ne [IntPtr]::Zero) { return $found }
    Start-Sleep -Milliseconds 400
  }
  return [IntPtr]::Zero
}

# ---------------------------------------------------------------- main
$result = [ordered]@{
  ok = $false; stage = 'start'; chat = ''; paths = @(); autoSend = $false
  window = $null; screenshot = $null; stages = @(); log = @(); error = $null
}

try {
  if ($Job) {
    if (-not (Test-Path -LiteralPath $Job)) { throw "job file not found: $Job" }
    $jobJson = [System.IO.File]::ReadAllText($Job, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($jobJson.paths) { $Paths = @($jobJson.paths) }
    if ($jobJson.chat) { $Chat = $jobJson.chat }
    if ($jobJson.PSObject.Properties.Name -contains 'autoSend') { $AutoSend = [bool]$jobJson.autoSend }
    if ($jobJson.screenshot) { $ScreenshotOut = $jobJson.screenshot }
    if ($jobJson.log) { $LogOut = $jobJson.log }
    if ($jobJson.PSObject.Properties.Name -contains 'loginOnly') { $LoginOnly = [bool]$jobJson.loginOnly }
  }
  if (-not $Chat) {
    # 文件传输助手, built from code points so file encoding can never corrupt it
    $Chat = [string]::Concat([char]0x6587, [char]0x4EF6, [char]0x4F20, [char]0x8F93, [char]0x52A9, [char]0x624B)
  }
  $result.chat = $Chat
  $result.autoSend = [bool]$AutoSend

  if (-not $LoginOnly) {
    Enter-Stage 'resolve-paths'
    $resolved = @()
    foreach ($p in @($Paths)) {
      if (-not $p) { continue }
      if (-not (Test-Path -LiteralPath $p)) { throw "file not found: $p" }
      $resolved += (Resolve-Path -LiteralPath $p).ProviderPath
    }
    if ($resolved.Count -eq 0) { throw 'no files to send' }
    $result.paths = $resolved
    Add-Log "files: $($resolved.Count)"
  }

  Enter-Stage 'find-window'
  $shortWait = [Math]::Max(2, [Math]::Min(4, $WindowWaitSeconds))
  $handle = Wait-WeChatWindow $shortWait

  # WeChat is not running at all: start it (never kill it) and wait for its window.
  if ($handle -eq [IntPtr]::Zero) {
    Enter-Stage 'launch-wechat'
    $exe = Get-WeixinExecutable
    if (-not $exe) {
      $result.stage = 'wechat-missing'
      throw 'WeChat is not running and Weixin.exe could not be found (is WeChat installed?)'
    }
    Add-Log "starting $exe"
    try {
      Start-Process -FilePath $exe | Out-Null
    } catch {
      Add-Log "launch failed: $($_.Exception.Message)"
    }
    $handle = Wait-WeChatWindow ([Math]::Max(30, $WindowWaitSeconds))
    if ($handle -eq [IntPtr]::Zero) {
      # WeChat occasionally exits right after being started; give it one more chance.
      Add-Log 'still no window, launching once more'
      try {
        Start-Process -FilePath $exe | Out-Null
      } catch {
        Add-Log "second launch failed: $($_.Exception.Message)"
      }
      $handle = Wait-WeChatWindow 20
    }
    if ($handle -eq [IntPtr]::Zero) {
      $result.stage = 'wechat-not-starting'
      throw 'WeChat did not open a window after being started'
    }
    Add-Log "WeChat window appeared: $handle"
  }

  $rect = New-Object Wx+RECT
  [void][Wx]::GetWindowRect($handle, [ref] $rect)
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  $result.window = [ordered]@{
    hwnd = [int64]$handle; title = [Wx]::Title($handle); visible = [Wx]::IsWindowVisible($handle)
    rect = [ordered]@{ x = $rect.Left; y = $rect.Top; width = $width; height = $height }
  }
  Add-Log "window $handle '$([Wx]::Title($handle))' ${width}x${height}"

  # ---------------------------------------------------------------- login
  # The login window is much smaller than the main window and shows either an avatar with a
  # 「进入微信」 button or a QR code. Only the button case can be automated.
  $loginRound = 0
  while (($width -lt 700 -or $height -lt 500) -and $loginRound -lt 3) {
    $loginRound++
    Enter-Stage 'login'
    if (-not $script:ocrOk) {
      $result.stage = 'ocr-unavailable'
      throw 'OCR is unavailable, cannot locate the login button'
    }
    [void][Wx]::Focus($handle)
    Start-Sleep -Milliseconds 400
    $button = $null
    $loginText = ''
    try {
      $shot = Get-WindowBitmap $handle
      try { $lines = Get-OcrLines $shot.bitmap } finally { $shot.bitmap.Dispose() }
      $loginText = (($lines | ForEach-Object { $_.text }) -join ' ')
      foreach ($line in $lines) {
        if (($line.text -replace '\s+', '') -like '*进入微信*') { $button = $line; break }
      }
    } catch {
      Add-Log "login OCR failed: $($_.Exception.Message)"
    }
    Add-Log "login window ${width}x${height}, OCR='$loginText'"
    if ($button) {
      $bx = $rect.Left + [int]($button.x + ($button.w / 2))
      $by = $rect.Top + [int]($button.y + ($button.h / 2))
      Add-Log "clicking 进入微信 at $bx,$by"
      [Wx]::ClickInput($bx, $by)
    } elseif (($loginText -replace '\s+', '') -match '扫码|二维码|扫描') {
      $result.stage = 'login-qr'
      Save-WindowShot $handle $ScreenshotOut
      $result.screenshot = $ScreenshotOut
      $result.error = 'WeChat wants a QR scan; scan it on the phone and retry'
      Write-Result $result
      exit 12
    } else {
      $bx = $rect.Left + [int]($width * 0.5)
      $by = $rect.Top + [int]($height * 0.74)
      Add-Log "login button not recognised; clicking the usual position $bx,$by"
      [Wx]::ClickInput($bx, $by)
      Start-Sleep -Milliseconds 600
      [Wx]::Enter()
    }
    $loginDeadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $loginDeadline) {
      Start-Sleep -Milliseconds 700
      $candidate = [Wx]::FindMain()
      if ($candidate -eq [IntPtr]::Zero) { continue }
      $crect = New-Object Wx+RECT
      [void][Wx]::GetWindowRect($candidate, [ref] $crect)
      $cw = $crect.Right - $crect.Left
      $ch = $crect.Bottom - $crect.Top
      if ($cw -ge 700 -and $ch -ge 500) {
        $handle = $candidate
        $rect = $crect
        $width = $cw
        $height = $ch
        break
      }
    }
  }
  if ($width -lt 700 -or $height -lt 500) {
    $result.stage = 'login-required'
    Save-WindowShot $handle $ScreenshotOut
    $result.screenshot = $ScreenshotOut
    $result.error = 'WeChat is still showing its login window; log in (QR scan on the phone) and retry'
    Write-Result $result
    exit 11
  }
  Enter-Stage 'logged-in'
  $result.window = [ordered]@{
    hwnd = [int64]$handle; title = [Wx]::Title($handle); visible = [Wx]::IsWindowVisible($handle)
    rect = [ordered]@{ x = $rect.Left; y = $rect.Top; width = $width; height = $height }
  }
  Add-Log "logged in, main window ${width}x${height}"
  if ($LoginOnly) {
    Save-WindowShot $handle $ScreenshotOut
    $result.screenshot = $ScreenshotOut
    $result.stage = 'logged-in'
    $result.ok = $true
    Write-Result $result
    exit 0
  }

  # The 📁 button, the 发送 button and the composer only sit where this engine looks them up
  # when the window is close to WeChat's default size (~1020x740). A maximised or heavily
  # shrunk window breaks that, so resize it for this run and put it back at the end.
  Enter-Stage 'normalize-window'
  $script:restoreHandle = $handle
  $targetW = 1020
  $targetH = 740
  $newX = [Math]::Max(0, $rect.Left)
  $newY = [Math]::Max(0, $rect.Top)
  try {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($vs.Width -gt 0 -and $vs.Height -gt 0) {
      $targetW = [Math]::Max(880, [Math]::Min($targetW, $vs.Width - 80))
      $targetH = [Math]::Max(620, [Math]::Min($targetH, $vs.Height - 80))
      $newX = [Math]::Max($vs.Left, [Math]::Min($rect.Left, $vs.Left + $vs.Width - $targetW - 20))
      $newY = [Math]::Max($vs.Top, [Math]::Min($rect.Top, $vs.Top + $vs.Height - $targetH - 20))
    }
  } catch {
    Add-Log "screen metrics unavailable: $($_.Exception.Message)"
  }
  if ([Math]::Abs($width - $targetW) -gt 40 -or [Math]::Abs($height - $targetH) -gt 40) {
    $script:restoreRect = @{ x = $rect.Left; y = $rect.Top; w = $width; h = $height }
    Add-Log "window ${width}x${height} is off-layout, resizing to ${targetW}x${targetH} at $newX,$newY"
    [void][Wx]::SetWindowPos($handle, [IntPtr]::Zero, $newX, $newY, $targetW, $targetH, 0x0004)
    Start-Sleep -Milliseconds 700
    $nowRect = New-Object Wx+RECT
    [void][Wx]::GetWindowRect($handle, [ref] $nowRect)
    $rect = $nowRect
    $width = $nowRect.Right - $nowRect.Left
    $height = $nowRect.Bottom - $nowRect.Top
    Add-Log "window is now ${width}x${height}"
  } else {
    Add-Log "window ${width}x${height} already fits the layout this engine uses"
  }
  $result.window = [ordered]@{
    hwnd = [int64]$handle; title = [Wx]::Title($handle); visible = [Wx]::IsWindowVisible($handle)
    rect = [ordered]@{ x = $rect.Left; y = $rect.Top; width = $width; height = $height }
    resized = [bool]$script:restoreRect
  }

  Enter-Stage 'focus'
  $focused = [Wx]::Focus($handle)
  Add-Log "foreground=$focused"
  Start-Sleep -Milliseconds 400

  Enter-Stage 'verify-chat'
  if (-not $script:ocrOk) {
    $result.stage = 'ocr-unavailable'
    throw 'OCR is unavailable, refusing to paste without verification'
  }
  $header = Get-WindowOcr $handle 0.44 0.040 0.55 0.10
  Add-Log "header='$header'"
  if (-not ($header -like "*$Chat*")) {
    # Try to select the chat from the conversation list. Clicking a row only switches the
    # open chat (never sends anything) and the header is re-verified afterwards.
    Enter-Stage 'open-chat'
    $want = $Chat -replace '\s+', ''
    $listX = $rect.Left + [int]($width * 0.26)
    $listY = $rect.Top + [int]($height * 0.50)
    for ($attempt = 0; $attempt -lt 4 -and -not ($header -like "*$Chat*"); $attempt++) {
      if ($attempt -gt 0) {
        [Wx]::Wheel($listX, $listY, -360)
        Start-Sleep -Milliseconds 700
      }
      try {
        $shot = Get-WindowBitmap $handle
        try { $lines = Get-OcrLines $shot.bitmap } finally { $shot.bitmap.Dispose() }
        $candidates = @($lines | Where-Object {
            (($_.text -replace '\s+', '') -like "*$want*") -and
            ($_.x -gt ($width * 0.08)) -and ($_.x -lt ($width * 0.46)) -and
            ($_.y -gt ($height * 0.08))
          })
        if ($candidates.Count -gt 0) {
          # Two rows with the same display name cannot be told apart by OCR, and the header
          # check after the click cannot help either - refuse instead of guessing.
          $rows = @()
          foreach ($candidate in $candidates) {
            $sameRow = $false
            foreach ($row in $rows) {
              if ([Math]::Abs($row.y - $candidate.y) -lt 24) { $sameRow = $true; break }
            }
            if (-not $sameRow) { $rows += $candidate }
          }
          if ($rows.Count -gt 1) {
            $result.stage = 'chat-ambiguous'
            Save-WindowShot $handle $ScreenshotOut
            $result.screenshot = $ScreenshotOut
            $result.error = "$($rows.Count) conversations in the list are called '$Chat' - OCR cannot tell them apart, open the right one yourself and retry"
            Write-Result $result
            exit 13
          }
          $target = $rows[0]
          $tx = $rect.Left + [int]($target.x + ($target.w / 2))
          $ty = $rect.Top + [int]($target.y + ($target.h / 2))
          Add-Log "clicking chat row at $tx,$ty ('$($target.text)')"
          [Wx]::ClickInput($tx, $ty)
          Start-Sleep -Milliseconds 1300
          $header = Get-WindowOcr $handle 0.44 0.040 0.55 0.10
          Add-Log "header after row click='$header'"
        } else {
          Add-Log "attempt $attempt : target chat row not visible"
        }
      } catch {
        Add-Log "open-chat failed: $($_.Exception.Message)"
      }
    }
  }
  if (-not ($header -like "*$Chat*")) {
    $result.stage = 'chat-not-open'
    Save-WindowShot $handle $ScreenshotOut
    $result.screenshot = $ScreenshotOut
    $result.error = "the open chat is not '$Chat' (header: '$header'); open that chat in WeChat and retry"
    Write-Result $result
    exit 6
  }

  Enter-Stage 'click-composer'
  [Wx]::ClickInput(($rect.Left + [int]($width * 0.55)), ($rect.Top + [int]($height * 0.72)))
  Start-Sleep -Milliseconds 350
  # empty-composer reference, used to recognise image cards that OCR cannot read
  $composerEmpty = $null
  try { $composerEmpty = Get-ComposerGrid $handle } catch { Add-Log "composer reference failed: $($_.Exception.Message)" }

  # WeChat 4.x does not accept a CF_HDROP paste into its composer (text pastes fine), so the
  # files are selected through its own 文件夹 button and the native "选择文件" dialog.
  Enter-Stage 'open-file-dialog'
  [Wx]::ClickInput(($rect.Left + [int]($width * 0.5906)), ($rect.Top + [int]($height * 0.9208)))
  $dialog = [IntPtr]::Zero
  $dialogSeen = $false
  $dialogDeadline = (Get-Date).AddSeconds(6)
  while ((Get-Date) -lt $dialogDeadline) {
    $dialog = [Wx]::FindDialog()
    if ($dialog -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 250
  }

  if ($dialog -ne [IntPtr]::Zero) {
    $dialogSeen = $true
    Add-Log "file dialog $dialog '$([Wx]::Title($dialog))'"
    Enter-Stage 'select-files'
    [void][Wx]::Focus($dialog)
    Start-Sleep -Milliseconds 500
    # the dialog's 文件名(N): edit sits at ~ (0.49w, 0.873h); clicking it guarantees the
    # clipboard paste lands in the filename box and not in the file list
    $dlgRect = New-Object Wx+RECT
    [void][Wx]::GetWindowRect($dialog, [ref] $dlgRect)
    $dlgW = $dlgRect.Right - $dlgRect.Left
    $dlgH = $dlgRect.Bottom - $dlgRect.Top
    $editX = $dlgRect.Left + [int]($dlgW * 0.49)
    $editY = $dlgRect.Top + [int]($dlgH * 0.873)
    Add-Log "click filename edit $editX,$editY"
    [Wx]::ClickInput($editX, $editY)
    Start-Sleep -Milliseconds 400
    $quoted = (@($resolved | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    [Wx]::SetClipboardText($quoted)
    Start-Sleep -Milliseconds 250
    [Wx]::CtrlV()
    Start-Sleep -Milliseconds 900
    [Wx]::Enter()
    $closeDeadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $closeDeadline -and [Wx]::IsWindow($dialog)) { Start-Sleep -Milliseconds 300 }
    $stillOpen = [Wx]::IsWindow($dialog)
    Add-Log "dialog still open=$stillOpen"
    # WeChat needs a moment between the dialog closing and the cards appearing.
    Start-Sleep -Milliseconds 1900

    Enter-Stage 'verify-paste'
    $composer = Get-WindowOcr $handle 0.44 0.60 0.55 0.35
    Add-Log "composer='$composer'"
    $seen = Test-AnyFileCard $composer $resolved
    if ($seen -eq 0) {
      # images (and any card whose text OCR cannot read) are recognised structurally
      try {
        $now = Get-ComposerGrid $handle
        if (Test-GridChanged $composerEmpty $now) {
          Add-Log 'composer changed structurally (image card)'
          $seen = 1
        }
      } catch { Add-Log "structural check failed: $($_.Exception.Message)" }
    }
    if ($seen -eq 0) {
      # retry only when the dialog is gone but nothing landed in the composer
      Add-Log 'files not visible after the dialog, retrying once'
      [Wx]::ClickInput(($rect.Left + [int]($width * 0.5906)), ($rect.Top + [int]($height * 0.9208)))
      Start-Sleep -Milliseconds 1800
      $dialog2 = [Wx]::FindDialog()
      if ($dialog2 -ne [IntPtr]::Zero) {
        [void][Wx]::Focus($dialog2)
        Start-Sleep -Milliseconds 500
        $dr2 = New-Object Wx+RECT
        [void][Wx]::GetWindowRect($dialog2, [ref] $dr2)
        [Wx]::ClickInput(($dr2.Left + [int](($dr2.Right - $dr2.Left) * 0.49)), ($dr2.Top + [int](($dr2.Bottom - $dr2.Top) * 0.873)))
        Start-Sleep -Milliseconds 400
        [Wx]::SetClipboardText($quoted)
        Start-Sleep -Milliseconds 250
        [Wx]::CtrlV()
        Start-Sleep -Milliseconds 900
        [Wx]::Enter()
        Start-Sleep -Milliseconds 2900
        $composer = Get-WindowOcr $handle 0.44 0.60 0.55 0.35
        Add-Log "composer after retry='$composer'"
        $seen = Test-AnyFileCard $composer $resolved
        if ($seen -eq 0) {
          try {
            if (Test-GridChanged $composerEmpty (Get-ComposerGrid $handle)) {
              Add-Log 'composer changed structurally after retry (image card)'
              $seen = 1
            }
          } catch { Add-Log "structural check failed: $($_.Exception.Message)" }
        }
      }
    }
  } else {
    $dialogSeen = $false
    Add-Log 'no file dialog appeared, falling back to the clipboard file paste'
    Enter-Stage 'paste-files'
    [Wx]::SetFileDrop($resolved)
    Start-Sleep -Milliseconds 250
    [Wx]::CtrlV()
    Start-Sleep -Milliseconds 1800
    Enter-Stage 'verify-paste'
    $composer = Get-WindowOcr $handle 0.44 0.60 0.55 0.35
    Add-Log "composer='$composer'"
    $seen = Test-AnyFileCard $composer $resolved
    if ($seen -eq 0) {
      try {
        if (Test-GridChanged $composerEmpty (Get-ComposerGrid $handle)) {
          Add-Log 'composer changed structurally after paste (image card)'
          $seen = 1
        }
      } catch { Add-Log "structural check failed: $($_.Exception.Message)" }
    }
  }

  Save-WindowShot $handle $ScreenshotOut
  $result.screenshot = $ScreenshotOut
  if ($seen -eq 0) {
    if (-not $dialogSeen) {
      # Neither the 📁 button nor a synthetic paste did anything: WeChat 4 does that when its
      # input handling wedges (the window still repaints and still answers WM_NULL).
      $result.stage = 'input-blocked'
      $result.error = 'wechat did not react to the file button or to a paste - restart WeChat (quit it from the tray) and try again'
      Write-Result $result
      exit 10
    }
    $result.stage = 'paste-not-verified'
    $result.error = 'the files did not show up in the chat composer'
    Write-Result $result
    exit 7
  }
  $result.staged = $seen
  # reference of the staged state: after a successful send the composer no longer shows it
  $composerStaged = $null
  try { $composerStaged = Get-ComposerGrid $handle } catch { Add-Log "staged reference failed: $($_.Exception.Message)" }

  if ($AutoSend) {
    Enter-Stage 'send'
    # the send button turns green once the composer holds something
    $sendX = $rect.Left + [int]($width * 0.915)
    $sendY = $rect.Top + [int]($height * 0.921)
    $green = $false
    try {
      $probe = New-Object System.Drawing.Bitmap 1, 1
      $pg = [System.Drawing.Graphics]::FromImage($probe)
      $pg.CopyFromScreen($sendX, $sendY, 0, 0, (New-Object System.Drawing.Size 1, 1))
      $pg.Dispose()
      $pixel = $probe.GetPixel(0, 0)
      $probe.Dispose()
      $green = ($pixel.G -gt 120) -and (($pixel.G - $pixel.R) -gt 40)
      Add-Log "send button pixel rgb($($pixel.R),$($pixel.G),$($pixel.B)) green=$green"
    } catch {
      Add-Log "send button probe failed: $($_.Exception.Message)"
    }
    $paneBefore = $null
    try { $paneBefore = Get-PaneGrid $handle } catch { Add-Log "pane reference failed: $($_.Exception.Message)" }
    [Wx]::ClickInput($sendX, $sendY)
    Start-Sleep -Milliseconds 2600
    Enter-Stage 'verify-send'
    $pane = Get-WindowOcr $handle 0.44 0.10 0.55 0.50
    $composerAfter = Get-WindowOcr $handle 0.44 0.60 0.55 0.35
    Add-Log "pane='$pane' composerAfter='$composerAfter'"
    $sent = Test-AnyFileCard $pane $resolved
    $composerChanged = $false
    $paneChanged = $false
    try {
      $composerChanged = Test-GridChanged $composerStaged (Get-ComposerGrid $handle)
      $paneChanged = Test-GridChanged $paneBefore (Get-PaneGrid $handle) 14 0.02
    } catch { Add-Log "structural send check failed: $($_.Exception.Message)" }
    Add-Log "sent-by-name=$sent composer-changed=$composerChanged pane-changed=$paneChanged"
    if ($sent -eq 0 -and $composerChanged -and $paneChanged) {
      # image cards cannot be read by OCR: a new bubble in the chat plus an emptied composer
      # is the signal (composer alone is not enough - its placeholder changes on hover)
      $sent = 1
    }
    Save-WindowShot $handle $ScreenshotOut
    $result.screenshot = $ScreenshotOut
    if ($sent -eq 0) {
      $result.stage = 'send-not-verified'
      $result.error = 'the files were staged but the message was not confirmed in the chat'
      Write-Result $result
      exit 8
    }
    $result.stage = 'sent'
  } else {
    $result.stage = 'staged'
  }

  $result.ok = $true
  $result.stages = $script:stages.ToArray()
  $result.log = $script:log.ToArray()
  Write-Result $result
  exit 0
} catch {
  if (-not $result.stage -or $result.stage -eq 'start') { $result.stage = 'error' }
  if (-not $result.error) { $result.error = $_.Exception.Message }
  $result.ok = $false
  $result.stages = $script:stages.ToArray()
  $result.log = $script:log.ToArray()
  Write-Result $result
  exit 9
} finally {
  # never leave the user's WeChat window at the size this run forced on it
  try { Restore-WeChatWindow } catch { }
}
