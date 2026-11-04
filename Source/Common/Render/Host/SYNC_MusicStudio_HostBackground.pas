unit SYNC_MusicStudio_HostBackground;

// Immutable input frames, owned by SDK effect lifetimes. The registry lends no
// session/SDK/VCL pointers to the settings timer and removes entries before free.
interface

uses System.Types, System.Generics.Collections, System.SyncObjs,
  AviUtl2FilterTypes, SYNC_MusicStudio_FramebufferCapture;

type
  TMusicStudioFramePixels = TArray<TPIXEL_RGBA>;
  TMusicStudioBackgroundSnapshot = record
    Pixels: TMusicStudioFramePixels;
    Width, Height, SceneID, Frame: Integer;
    Seconds: Double;
    Serial: UInt64;
    Status: string;
  end;
  TMusicStudioReadBackground = function(AfterSerial: UInt64;
    out Snapshot: TMusicStudioBackgroundSnapshot): Boolean of object;

  TMusicStudioHostBackground = class
  private
    FOwner: OBJECT_HANDLE;
    FSnapshot: TMusicStudioBackgroundSnapshot;
    FFramebuffer: TMusicStudioFramebufferCapture;
  public
    constructor Create;
    destructor Destroy; override;
    // Pixels must be a newly allocated, complete pre-overlay input buffer.
    // Publish freezes it; neither the producer nor registry modifies it later.
    procedure Publish(Owner: OBJECT_HANDLE; SceneID,Frame,Width,Height: Integer;
      Seconds: Double; const Pixels: TMusicStudioFramePixels; const Status: string = '');
    procedure Clear(const Status: string = '');
    function CaptureFramebuffer(GetTexture: TFILTER_PROC_VIDEO_GET_TEX2D;
      out Pixels: TMusicStudioFramePixels; out Width,Height: Integer;
      out Status: string): Boolean;
  end;

// The copy is owned by the UI. An unchanged serial avoids copying full frames.
function ReadMusicStudioBackground(Owner: OBJECT_HANDLE; SceneID: Integer;
  AfterSerial: UInt64; out Snapshot: TMusicStudioBackgroundSnapshot): Boolean;
function MusicStudioCharacterRect(FrameWidth,FrameHeight,Count,Index,
  ImageWidth,ImageHeight: Integer): TRect;
function MusicStudioFitFrameRect(const Bounds: TRect; Width,Height: Integer): TRect;

implementation

uses System.SysUtils, System.Math;

var Lock: TCriticalSection; Entries: TList<TMusicStudioHostBackground>;
    NextSerial: UInt64; LastCaptureStatus: string;

constructor TMusicStudioHostBackground.Create;
begin
  inherited;
  FFramebuffer := TMusicStudioFramebufferCapture.Create;
  Lock.Acquire;
  try Entries.Add(Self); finally Lock.Release; end;
end;

destructor TMusicStudioHostBackground.Destroy;
begin
  Lock.Acquire;
  try Entries.Remove(Self); FSnapshot := Default(TMusicStudioBackgroundSnapshot);
  finally Lock.Release; end;
  FFramebuffer.Free;
  inherited;
end;

function TMusicStudioHostBackground.CaptureFramebuffer(GetTexture: TFILTER_PROC_VIDEO_GET_TEX2D;
  out Pixels: TMusicStudioFramePixels; out Width,Height: Integer; out Status: string): Boolean;
begin Result := FFramebuffer.Capture(GetTexture,Pixels,Width,Height,Status); end;

procedure TMusicStudioHostBackground.Clear(const Status: string);
begin
  Lock.Acquire;
  try FOwner := nil; FSnapshot := Default(TMusicStudioBackgroundSnapshot);
    LastCaptureStatus := Status;
  finally Lock.Release; end;
end;

procedure TMusicStudioHostBackground.Publish(Owner: OBJECT_HANDLE;
  SceneID,Frame,Width,Height: Integer; Seconds: Double;
  const Pixels: TMusicStudioFramePixels; const Status: string);
begin
  if (Owner=nil) or (Width<1) or (Height<1) or (Width>8192) or
    (Height>8192) or (Int64(Width)*Height>33554432) or
    (Length(Pixels)<>Int64(Width)*Height) or IsNan(Seconds) or IsInfinite(Seconds) then
  begin Clear(Status); Exit; end;
  Lock.Acquire;
  try
    FOwner := Owner; FSnapshot.Pixels := Pixels;
    FSnapshot.Width := Width; FSnapshot.Height := Height;
    FSnapshot.SceneID := SceneID; FSnapshot.Frame := Frame;
    FSnapshot.Seconds := Seconds; Inc(NextSerial); FSnapshot.Serial := NextSerial;
    FSnapshot.Status := Status; LastCaptureStatus := Status;
  finally Lock.Release; end;
end;

function ReadMusicStudioBackground(Owner: OBJECT_HANDLE; SceneID: Integer;
  AfterSerial: UInt64; out Snapshot: TMusicStudioBackgroundSnapshot): Boolean;
var Entry,Match: TMusicStudioHostBackground;
begin
  Result := False; Snapshot := Default(TMusicStudioBackgroundSnapshot);
  if Owner=nil then Exit;
  Lock.Acquire;
  try
    Snapshot.Status := '背景未取得: この対象の描画前画像を待っています。';
    if LastCaptureStatus<>'' then Snapshot.Status := Snapshot.Status+sLineBreak+LastCaptureStatus;
    Match := nil;
    for Entry in Entries do
      // A render read-section can legally omit EDIT_INFO. OBJECT_HANDLE still
      // identifies the same live object across scenes; known scenes stay strict.
      if (Entry.FOwner=Owner) and ((Entry.FSnapshot.SceneID=SceneID) or
        (Entry.FSnapshot.SceneID<0) or (SceneID<0)) then begin
        // Ambiguous identity never borrows another effect's frame.
        if Match<>nil then begin Snapshot.Status := '背景未取得: 同じ対象の取得元が複数あり特定できません。'; Exit; end;
        Match := Entry;
      end;
    if Match=nil then Exit;
    Snapshot := Match.FSnapshot;
    if Snapshot.Serial=AfterSerial then Snapshot.Pixels := nil
    else Snapshot.Pixels := Copy(Snapshot.Pixels);
    Result := True;
  finally Lock.Release; end;
end;

function MusicStudioCharacterRect(FrameWidth,FrameHeight,Count,Index,
  ImageWidth,ImageHeight: Integer): TRect;
var LaneWidth,W,H,L: Integer; Scale: Double;
begin
  Result := TRect.Empty;
  if (FrameWidth<1) or (FrameHeight<1) or (Count<1) or (Index<0) or
    (Index>=Count) or (ImageWidth<1) or (ImageHeight<1) then Exit;
  LaneWidth := Max(1,FrameWidth div Count);
  Scale := Min(LaneWidth/ImageWidth,FrameHeight/ImageHeight);
  W := Max(1,Round(ImageWidth*Scale)); H := Max(1,Round(ImageHeight*Scale));
  L := Index*FrameWidth div Count+(LaneWidth-W) div 2;
  Result := Rect(L,FrameHeight-H,Min(FrameWidth,L+W),FrameHeight);
end;

function MusicStudioFitFrameRect(const Bounds: TRect; Width,Height: Integer): TRect;
var Scale: Double; W,H,L,T: Integer;
begin
  Result := TRect.Empty;
  if (Bounds.Width<1) or (Bounds.Height<1) or (Width<1) or (Height<1) then Exit;
  Scale := Min(Bounds.Width/Width,Bounds.Height/Height);
  W := Max(1,Round(Width*Scale)); H := Max(1,Round(Height*Scale));
  L := Bounds.Left+(Bounds.Width-W) div 2; T := Bounds.Top+(Bounds.Height-H) div 2;
  Result := Rect(L,T,L+W,T+H);
end;

initialization
  Lock := TCriticalSection.Create; Entries := TList<TMusicStudioHostBackground>.Create;
finalization
  Entries.Free; Lock.Free;
end.
