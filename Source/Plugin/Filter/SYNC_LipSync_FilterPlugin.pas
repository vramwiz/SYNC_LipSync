unit SYNC_LipSync_FilterPlugin;

// AviUtl2のABI境界。設定対象の固定、描画インスタンスと背景スナップショットを管理する。

interface

uses
  AviUtl2FilterTypes;

// DLLが所有する登録テーブルを返す。ホストはプラグインのロード中だけ参照する。
function GetLipSyncFilterTable: PFILTER_PLUGIN_TABLE;
procedure SetLipSyncHostVersion(Version: Cardinal);

implementation

uses
  System.SysUtils, System.Math, System.Types, System.SyncObjs, System.UITypes,
  Vcl.Dialogs, Vcl.Graphics,
  PluginFilterTable, SYNC_LipSync_ArrangementForm, SYNC_LipSync_Scene,
  SYNC_LipSync_Project, SYNC_LipSync_Presentation,
  SYNC_MusicStudio_HostBackground;

const
  EFFECT_NAME = '口パク';
  PSD_ITEM_NAME = 'PSDファイル';
  MUSIC_ITEM_NAME = '音楽ファイル';
  JSON_ITEM_NAME = 'JSONデータ';
  DEFAULT_JSON = '{}';

type
  TSettingsSession = class
    Edit: PEDIT_SECTION;
    Obj: OBJECT_HANDLE;
    SceneID, CursorFrame: Integer;
    function ReadBackground(AfterSerial: UInt64;
      out Snapshot: TMusicStudioBackgroundSnapshot): Boolean;
    function ReadItem(Name: PWideChar): string;
    procedure Save(const PsdPath, MusicPath, JSON: string);
  end;

  TLipSyncVideoSession = class
    Lock: TCriticalSection;
    Scene: TLipSyncScene;
    Arrangement: TLipSyncProject;
    ArrangementJSON: string;
    Background: TMusicStudioHostBackground;
    Image: TBitmap;
    constructor Create;
    destructor Destroy; override;
    procedure Render(Video: PFILTER_PROC_VIDEO);
    procedure CaptureBackground(Video: PFILTER_PROC_VIDEO;
      const Input: TMusicStudioFramePixels; Width, Height: Integer);
  end;

var
  SettingsButton: TFILTER_ITEM_BUTTON;
  PSDItem, MusicItem: TFILTER_ITEM_FILE;
  JSONDataItem: TFILTER_ITEM_STRING;
  VideoOffsetItem: TFILTER_ITEM_TRACK;
  PluginTableInitialized: Boolean;
  HostVersion: Cardinal;

procedure SetLipSyncHostVersion(Version: Cardinal);
begin
  HostVersion := Version;
end;

function TSettingsSession.ReadBackground(AfterSerial: UInt64;
  out Snapshot: TMusicStudioBackgroundSnapshot): Boolean;
begin
  Result := ReadMusicStudioBackground(Obj, SceneID, AfterSerial, Snapshot);
  if Result and (CursorFrame >= 0) and (Snapshot.Frame <> CursorFrame) then
    Snapshot.Status := Format('%s（取得フレーム %d / カーソル %d）',
      [Snapshot.Status, Snapshot.Frame, CursorFrame]);
end;

function TSettingsSession.ReadItem(Name: PWideChar): string;
var
  Value: PAnsiChar;
begin
  Value := Edit^.GetObjectItemValue(Obj, EFFECT_NAME, Name);
  if Value = nil then
    raise Exception.CreateFmt('「%s」を取得できませんでした。', [string(Name)]);
  Result := string(UTF8String(Value));
end;

procedure TSettingsSession.Save(const PsdPath, MusicPath, JSON: string);
var
  Names: array[0..2] of PWideChar;
  Previous, Updated: array[0..2] of UTF8String;
  Changed: array[0..2] of Boolean;
  I, J: Integer;
  Restored: Boolean;
begin
  Names[0] := PSD_ITEM_NAME;
  Names[1] := MUSIC_ITEM_NAME;
  Names[2] := JSON_ITEM_NAME;
  Updated[0] := UTF8String(PsdPath);
  Updated[1] := UTF8String(MusicPath);
  Updated[2] := UTF8String(JSON);
  for I := 0 to High(Names) do
  begin
    Previous[I] := UTF8String(ReadItem(Names[I]));
    Changed[I] := False;
  end;
  for I := 0 to High(Names) do
    if Updated[I] <> Previous[I] then
    begin
      if not Edit^.SetObjectItemValue(Obj, EFFECT_NAME, Names[I], PAnsiChar(Updated[I])) then
      begin
        Restored := True;
        for J := I - 1 downto 0 do
          if Changed[J] and
            not Edit^.SetObjectItemValue(Obj, EFFECT_NAME, Names[J], PAnsiChar(Previous[J])) then
            Restored := False;
        if not Restored then
          raise Exception.Create('設定の保存に失敗し、一部を元に戻せませんでした。');
        raise Exception.CreateFmt('「%s」を保存できませんでした。', [string(Names[I])]);
      end;
      Changed[I] := True;
    end;
end;

procedure SettingsButtonCallback(Edit: PEDIT_SECTION); cdecl;
var
  Session: TSettingsSession;
  Form: TFormLipSyncArrangement;
  Info: PEDIT_INFO;
  Width, Height: Integer;
begin
  try
    if (Edit = nil) or not Assigned(Edit^.GetFocusObject) or
      not Assigned(Edit^.GetObjectItemValue) or not Assigned(Edit^.SetObjectItemValue) then
      raise Exception.Create('AviUtl2の編集APIを取得できませんでした。');

    Session := TSettingsSession.Create;
    try
      Session.Edit := Edit;
      Session.Obj := Edit^.GetFocusObject;
      if Session.Obj = nil then
        raise Exception.Create('設定対象のオブジェクトを選択してください。');
      if Assigned(Edit^.CountObjectEffect) and
        (Edit^.CountObjectEffect(Session.Obj, EFFECT_NAME) <> 1) then
        raise Exception.Create('設定対象には口パクを1つ配置してください。');

      Width := 1920;
      Height := 1080;
      Session.SceneID := -1;
      Session.CursorFrame := -1;
      Info := Edit^.Info;
      if Info <> nil then
      begin
        Width := Info^.Width;
        Height := Info^.Height;
        Session.SceneID := Info^.SceneID;
        Session.CursorFrame := Info^.Frame;
      end;
      Form := TFormLipSyncArrangement.Create(nil);
      try
        Form.LoadProject(Session.ReadItem(PSD_ITEM_NAME), Session.ReadItem(MUSIC_ITEM_NAME),
          Session.ReadItem(JSON_ITEM_NAME), Width, Height, Session.ReadBackground,
          procedure(const PsdPath, MusicPath, JSON: string)
          begin
            Session.Save(PsdPath, MusicPath, JSON);
          end);
        Form.ShowModal;
      finally
        Form.Free;
      end;
    finally
      Session.Free;
    end;
  except
    on E: Exception do
      try
        MessageDlg('口パクの設定: ' + E.Message, mtError, [mbOK], 0);
      except
        // Delphi例外をAviUtl2のコールバック境界へ漏らさない。
      end;
  end;
end;

constructor TLipSyncVideoSession.Create;
begin
  inherited;
  Lock := TCriticalSection.Create;
  Scene := TLipSyncScene.Create;
  Background := TMusicStudioHostBackground.Create;
  Image := TBitmap.Create;
end;

destructor TLipSyncVideoSession.Destroy;
begin
  Background.Free;
  Image.Free;
  Arrangement.Free;
  Scene.Free;
  Lock.Free;
  inherited;
end;

procedure TLipSyncVideoSession.CaptureBackground(Video: PFILTER_PROC_VIDEO;
  const Input: TMusicStudioFramePixels; Width, Height: Integer);
var
  Owner: OBJECT_HANDLE;
  Edit: PEDIT_SECTION;
  Layer, Frame, SceneID: Integer;
  Snapshot: TMusicStudioFramePixels;
  CaptureWidth, CaptureHeight: Integer;
  Status: string;
begin
  Edit := Video^.Edit;
  if (Edit = nil) or not Assigned(Edit^.FindObject) or
    not Assigned(Edit^.CountObjectEffect) then
  begin
    Background.Clear;
    Exit;
  end;
  Layer := Video^.Object_^.Layer;
  if Video^.Object_^.Flag and 1 <> 0 then
  begin
    if HostVersion < 2010300 then
    begin
      Background.Clear;
      Exit;
    end;
    Layer := Video^.Object_^.EffectLayer;
  end;
  Frame := Video^.Object_^.FrameS + Video^.Object_^.Frame;
  Owner := Edit^.FindObject(Layer, Frame);
  if (Owner = nil) or (Edit^.CountObjectEffect(Owner, EFFECT_NAME) <> 1) then
  begin
    Background.Clear;
    Exit;
  end;
  SceneID := -1;
  if Edit^.Info <> nil then SceneID := PEDIT_INFO(Edit^.Info)^.SceneID;

  if Background.CaptureFramebuffer(Video^.GetFramebufferTexture2D,
    Snapshot, CaptureWidth, CaptureHeight, Status) then
    Background.Publish(Owner, SceneID, Frame, CaptureWidth, CaptureHeight,
      Video^.Object_^.Time, Snapshot, 'AviUtl2 合成画面')
  else if Length(Input) > 0 then
    Background.Publish(Owner, SceneID, Frame, Width, Height,
      Video^.Object_^.Time, Copy(Input), 'AviUtl2 入力画像')
  else
    Background.Clear;
end;

procedure TLipSyncVideoSession.Render(Video: PFILTER_PROC_VIDEO);
var
  Width, Height, I: Integer;
  Pixels: TMusicStudioFramePixels;
  InputAvailable, Rendered, IsArrangement: Boolean;
  JSON: string;
  Character: TLipSyncCharacter;
  Presentation: TLipSyncPresentationFrame;
  Frame, Bounds: TRect;
  RenderSeconds: Double;

  procedure Composite(const Bounds: TRect; SourceOpacity: Byte);
  var
    X, Y, SX, SY, Inverse, SrcR, SrcG, SrcB, SrcA: Integer;
    Row: PByte;
    Clipped: TRect;
  begin
    if not IntersectRect(Clipped, Bounds, Rect(0, 0, Width, Height)) then Exit;
    if Length(Pixels) = 0 then SetLength(Pixels, NativeInt(Width) * Height);
    Rendered := True;
    // PSDのpremultiplied BGRAをAviUtl2のpremultiplied RGBAへ合成する。
    for Y := Clipped.Top to Clipped.Bottom - 1 do
    begin
      SY := Int64(Y - Bounds.Top) * Image.Height div Bounds.Height;
      Row := Image.ScanLine[SY];
      for X := Clipped.Left to Clipped.Right - 1 do
      begin
        SX := 4 * (Int64(X - Bounds.Left) * Image.Width div Bounds.Width);
        SrcA := Row[SX + 3];
        if SrcA = 0 then Continue;
        SrcR := Row[SX + 2];
        SrcG := Row[SX + 1];
        SrcB := Row[SX];
        // premultiplied形式では色とアルファの両方にフェードを掛ける。
        if SourceOpacity <> 255 then
        begin
          SrcA := (SrcA * SourceOpacity + 127) div 255;
          SrcR := (SrcR * SourceOpacity + 127) div 255;
          SrcG := (SrcG * SourceOpacity + 127) div 255;
          SrcB := (SrcB * SourceOpacity + 127) div 255;
        end;
        Inverse := 255 - SrcA;
        with Pixels[Y * Width + X] do
        begin
          R := Min(255, SrcR + (Integer(R) * Inverse + 127) div 255);
          G := Min(255, SrcG + (Integer(G) * Inverse + 127) div 255);
          B := Min(255, SrcB + (Integer(B) * Inverse + 127) div 255);
          A := Min(255, SrcA + (Integer(A) * Inverse + 127) div 255);
        end;
      end;
    end;
  end;

begin
  Width := Video^.Object_^.Width;
  Height := Video^.Object_^.Height;
  InputAvailable := (Width > 0) and (Height > 0) and Assigned(Video^.GetImageData);
  if (Width < 1) or (Height < 1) then
  begin
    Width := Video^.Scene^.Width;
    Height := Video^.Scene^.Height;
  end;
  if (Width < 1) or (Height < 1) or (Width > 8192) or (Height > 8192) or
    (Int64(Width) * Height > 33554432) then Exit;

  if InputAvailable then
  begin
    SetLength(Pixels, NativeInt(Width) * Height);
    Video^.GetImageData(@Pixels[0]);
  end;
  CaptureBackground(Video, Pixels, Width, Height);

  // 正のオフセットは描画を遅らせる。開始前はホスト画像を維持する。
  RenderSeconds := Video^.Object_^.Time-VideoOffsetItem.Value;
  if RenderSeconds<0 then Exit;

  JSON := string(JSONDataItem.Value);
  if JSON <> ArrangementJSON then
  begin
    FreeAndNil(Arrangement);
    IsArrangement := HasLipSyncArrangement(JSON);
    if IsArrangement then Arrangement := TLipSyncProject.Create('', '', JSON);
    ArrangementJSON := JSON;
  end;
  Rendered := False;
  Frame := Rect(0,0,Width,Height);
  if Assigned(Arrangement) then
  begin
    for I := Arrangement.Characters.Count - 1 downto 0 do
    begin
      Character := Arrangement.Characters[I];
      Presentation := Character.PresentationAt(Arrangement.Timing,RenderSeconds);
      if Presentation.Opacity = 0 then Continue;
      if (Character.Clips.Count = 0) and Assigned(Arrangement.Audio) and
        not Arrangement.Audio.Done then Arrangement.Audio.WaitFor;
      if Character.Render(Image,Arrangement.Timing,Arrangement.Audio,RenderSeconds) then
      begin
        Bounds := Character.Scene.Placement(Frame,Width,Height);
        Composite(Presentation.AdjustBounds(Frame,Bounds),Presentation.Opacity);
      end;
    end;
  end
  else
  begin
    Scene.Configure(string(PSDItem.Value), string(MusicItem.Value), JSON);
    if not Scene.Document.Loaded then Exit;
    Scene.WaitForMusic;
    if Scene.Render(Image,RenderSeconds) then
      Composite(Scene.Placement(Frame,Width,Height),255);
  end;
  if Rendered then Video^.SetImageData(@Pixels[0], Width, Height);
end;

function LipSyncProcVideo(Video: PFILTER_PROC_VIDEO): Byte; cdecl;
var
  Session: TLipSyncVideoSession;
begin
  Result := 1;
  try
    if (Video = nil) or (Video^.Object_ = nil) or (Video^.Scene = nil) or
      (Video^.UserData = nil) or not Assigned(Video^.SetImageData) then Exit;
    Session := TLipSyncVideoSession(Video^.UserData);
    Session.Lock.Acquire;
    try
      Session.Render(Video);
    finally
      Session.Lock.Release;
    end;
  except
    // 素材・ホストAPIの異常時は入力画像を維持する。
  end;
end;

function LipSyncCreate(EffectID: Int64): Pointer; cdecl;
begin
  Result := nil;
  try
    Result := TLipSyncVideoSession.Create;
  except
  end;
end;

procedure LipSyncDestroy(EffectID: Int64; UserData: Pointer); cdecl;
begin
  try
    TLipSyncVideoSession(UserData).Free;
  except
  end;
end;

function GetLipSyncFilterTable: PFILTER_PLUGIN_TABLE;
begin
  if not PluginTableInitialized then
  begin
    SetupPluginTable(FILTER_FLAG_VIDEO or FILTER_FLAG_FILTER or FILTER_FLAG_USERDATA,
      EFFECT_NAME, 'SYNC', 'PSDと音楽ファイルによる口パク', LipSyncProcVideo, nil);
    AddButton(SettingsButton, '設定', SettingsButtonCallback);
    AddFile(MusicItem, MUSIC_ITEM_NAME, '', LIP_SYNC_MUSIC_CAPTION + #0 + LIP_SYNC_MUSIC_MASK + #0#0);
    AddFile(PSDItem, PSD_ITEM_NAME, '', LIP_SYNC_PSD_CAPTION + #0 + LIP_SYNC_PSD_MASK + #0#0);
    AddString(JSONDataItem, JSON_ITEM_NAME, DEFAULT_JSON);
    AddTrack(VideoOffsetItem,'オフセット',0,-1,1,0.01);
    GetPluginTable^.Func_Create := LipSyncCreate;
    GetPluginTable^.Func_Destroy := LipSyncDestroy;
    PluginTableInitialized := True;
  end;
  Result := GetPluginTable;
end;

end.
