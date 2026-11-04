unit SYNC_LipSync_Scene;

// 素材形式による同期、PSD差分の選択とシーン上の配置を担当する。

interface

uses
  System.JSON, System.Types, Vcl.Graphics,
  SYNC_MusicStudio_AudioWaveform, SYNC_MusicStudio_SingingData,
  SYNC_MusicStudio_PsdLayers, SYNC_MusicStudio_PsdTransform;

type
  TLipSyncMode = (lmNone, lmEnvelope, lmPhonemes);
  TLipSyncEye = (leOpen, leHalf, leClosed);

  TLipSyncScene = class
  private
    FDocument: TMusicStudioLayerDocument;
    FConfig: TJSONObject;
    FJSON, FPsdPath, FMusicPath: string;
    FMode: TLipSyncMode;
    FVoice: TMusicStudioWaveJob;
    FSinging: TMusicStudioSingingSource;
    FTrack: Integer;
    procedure SelectTrack;
    procedure ApplyEye(Overrides, Config: TJSONObject; Eye: TLipSyncEye);
  public
    constructor Create;
    destructor Destroy; override;
    // 素材は読取専用。設定変更時だけ解析を開始し、音声解析はワーカーが所有する。
    procedure Configure(const PsdPath, MusicPath, JSON: string);
    // 呼出側のBitmapへ描画する。Slot=-1は時刻同期、0..10は指定した口差分。
    // PreviewLayerとExpressionは試写レイヤー・表示差分を借用し、基本設定には反映しない。
    function Render(Bitmap: TBitmap; Seconds: Double; Slot: Integer = -1;
      const PreviewLayer: string = ''; FixedSizeStep: Integer = 4;
      Expression: TJSONObject = nil; BlinkSeconds: Double = -1): Boolean;
    // 口差分と独立した決定的な瞬き。設定されていない差分は描画へ影響しない。
    function EyeAt(Seconds: Double): TLipSyncEye;
    // 指定の素材内時刻で使う口差分番号と開閉段階を返す。
    procedure MouthAt(Seconds: Double; out Slot, SizeStep: Integer);
    function HasEyeAssignment: Boolean;
    // 旧百分率は指定した出力サイズで中心原点の配置に換算する。保存値は変更しない。
    function TransformFor(FrameWidth, FrameHeight: Integer): TMusicStudioPsdTransform;
    function Placement(const Frame: TRect; OutputWidth, OutputHeight: Integer): TRect; overload;
    function Placement(const Frame: TRect; OutputWidth, OutputHeight: Integer;
      const Transform: TMusicStudioPsdTransform): TRect; overload;
    function MusicStatus: string;
    // 解析済みの試写素材の秒数。未設定・解析中は 0 を返す。
    function MusicDuration: Double;
    // 映像出力時に音声解析の完了を待つ。編集画面は解析中でも試写できる。
    procedure WaitForMusic;
    property Document: TMusicStudioLayerDocument read FDocument;
  end;

const
  LIP_SYNC_EYE_NAMES: array[TLipSyncEye] of string = ('開眼','半目','閉眼');
  LIP_SYNC_SLOT_NAMES: array[0..10] of string =
    ('閉じ', 'あ', 'い', 'う', 'え', 'お', 'ん', 'やや閉じ', '半開き', '開き', 'やや開き');
  // 閉じから開きへの順序。既存の割当キーと番号は保持する。
  LIP_SYNC_OPENING_SLOTS: array[0..4] of Integer = (0,7,8,10,9);
  LIP_SYNC_SAMPLE_SECONDS = 3.2;
  LIP_SYNC_MUSIC_MASK = '*.wav;*.mp3;*.mid;*.midi;*.kar;*.ust;*.vsqx;*.musicxml;*.mxl;*.xml;*.mscx;*.mscz';
  LIP_SYNC_MUSIC_CAPTION = '音楽 (WAV / MP3 / MIDI / 歌唱データ)';
  LIP_SYNC_PSD_MASK = '*.psd';
  LIP_SYNC_PSD_CAPTION = 'Photoshop PSD (*.psd)';

function LipSyncMode(const Path: string): TLipSyncMode;
function LipSyncLayer(Config: TJSONObject; Slot: Integer): string;
procedure AssignLipSyncLayer(Config: TJSONObject; Slot: Integer; const Key: string);
function LipSyncNumber(Config: TJSONObject; const Key: string; Default, Low, High: Double): Double;
function LipSyncEyeLayer(Config: TJSONObject; Eye: TLipSyncEye): string;
procedure AssignLipSyncEye(Config: TJSONObject; Eye: TLipSyncEye; const Key: string);
// 固定試写サンプルの音素と開閉段階を返す。実際の素材の時刻には影響しない。
procedure LipSyncSampleMouth(Seconds, Speed: Double; out SongSlot, Opening: Integer);

// 音量がしきい値を超えたときの口差分番号と開閉段階を求める。
procedure LipSyncVolumeMouth(Peak, Threshold: Double; out Slot, SizeStep: Integer);
function LipSyncSingingTrack(const Source: TMusicStudioSingingSource): Integer;
// 歌唱素材内の秒位置を、口差分の番号と縮小段階に変換する。
procedure LipSyncSingingMouth(const Notes: TMusicStudioSingingNotes; Track: Integer;
  Seconds: Double; out Slot, SizeStep: Integer);
function LipSyncVowelCaption(const Vowels: string): string;

implementation

uses
  System.SysUtils, System.Math,
  SYNC_MusicStudio_HostBackground, SYNC_MusicStudio_PsdLayerConfig, SYNC_MusicStudio_SingingFormats;

const
  EYE_KEYS: array[TLipSyncEye] of string = ('eyeOpen','eyeHalf','eyeClosed');
  SIMPLE_KEYS: array[7..10] of string = ('openSmall', 'openMedium', 'openFull', 'openWide');
  MOUTH_SCALES: array[1..4] of Double = (0.55, 0.78, 0.90, 1.0);

function LipSyncMode(const Path: string): TLipSyncMode;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(Path));
  if (Ext = '.wav') or (Ext = '.mp3') then Exit(lmEnvelope);
  if (Ext = '.mid') or (Ext = '.midi') or (Ext = '.kar') or MusicStudioStructuredSong(Ext) then Exit(lmPhonemes);
  Result := lmNone;
end;

function LipSyncLayer(Config: TJSONObject; Slot: Integer): string;
begin
  if Slot <= 6 then
    Result := MusicStudioMouthLayer(Config, Slot)
  else
    Result := Config.GetValue<string>(SIMPLE_KEYS[Slot], '');
end;

procedure AssignLipSyncLayer(Config: TJSONObject; Slot: Integer; const Key: string);
begin
  if Slot <= 6 then
    MusicStudioAssignMouth(Config, Slot, Key)
  else
  begin
    Config.RemovePair(SIMPLE_KEYS[Slot]).Free;
    if Key <> '' then Config.AddPair(SIMPLE_KEYS[Slot], Key);
  end;
end;

function LipSyncNumber(Config: TJSONObject; const Key: string; Default, Low, High: Double): Double;
begin
  Result := Config.GetValue<Double>(Key, Default);
  if IsNan(Result) or IsInfinite(Result) then Result := Default;
  Result := EnsureRange(Result, Low, High);
end;

constructor TLipSyncScene.Create;
begin
  inherited;
  FDocument := TMusicStudioLayerDocument.Create;
end;

destructor TLipSyncScene.Destroy;
begin
  FVoice.Free;
  FConfig.Free;
  FDocument.Free;
  inherited;
end;

function LipSyncSingingTrack(const Source: TMusicStudioSingingSource): Integer;
var
  Track: TMusicStudioSingingTrack;
  BestCount: Integer;
begin
  BestCount := 0;
  Result := -1;
  for Track in Source.Tracks do
    if Track.LyricCount > BestCount then
    begin
      BestCount := Track.LyricCount;
      Result := Track.Index;
    end;
end;

function LipSyncVowelCaption(const Vowels: string): string;
const
  Kana: string = 'あいうえおん';
var
  Vowel: Char;
  Index: Integer;
begin
  Result := '';
  for Vowel in Vowels do
  begin
    Index := Pos(Vowel, 'aiueon');
    if Index > 0 then Result := Result + Kana[Index] else Result := Result + '?';
  end;
end;

procedure LipSyncSingingMouth(const Notes: TMusicStudioSingingNotes; Track: Integer;
  Seconds: Double; out Slot, SizeStep: Integer);
var
  Latest, Fraction: Double;
  Note: TMusicStudioSingingNote;
  Index: Integer;
begin
  Slot := 0;
  SizeStep := High(LIP_SYNC_OPENING_SLOTS);
  if Track < 0 then Exit;
  Latest := -1;
  for Note in Notes do
    if (Note.TrackIndex = Track) and (Note.Vowels <> '') and
      (Note.StartSeconds >= Latest) and (Seconds >= Note.StartSeconds) and
      (Seconds < Note.EndSeconds) then
    begin
      Latest := Note.StartSeconds;
      Fraction := (Seconds - Note.StartSeconds) / (Note.EndSeconds - Note.StartSeconds);
      Index := EnsureRange(1 + Floor(Fraction * Length(Note.Vowels)), 1, Length(Note.Vowels));
      Slot := Pos(Note.Vowels[Index], 'aiueon');
      Fraction := Frac(Fraction * Length(Note.Vowels));
      SizeStep := EnsureRange(Ceil(High(LIP_SYNC_OPENING_SLOTS)*Sin(Pi*Fraction)),1,High(LIP_SYNC_OPENING_SLOTS));
    end;
end;

procedure TLipSyncScene.SelectTrack;
begin
  FTrack := LipSyncSingingTrack(FSinging);
end;

procedure TLipSyncScene.Configure(const PsdPath, MusicPath, JSON: string);
var
  Config: TJSONObject;
begin
  if FPsdPath <> PsdPath then
  begin
    FPsdPath := PsdPath;
    FDocument.LoadFile(PsdPath);
  end;

  if FMusicPath <> MusicPath then
  begin
    FreeAndNil(FVoice);
    FMusicPath := MusicPath;
    FSinging := Default(TMusicStudioSingingSource);
    FMode := LipSyncMode(MusicPath);
    case FMode of
      lmEnvelope:
        begin
          FVoice := TMusicStudioWaveJob.Create(MusicPath, 0);
          FVoice.Start;
        end;
      lmPhonemes:
        begin
          FSinging := LoadMusicStudioSinging(MusicPath);
          SelectTrack;
        end;
    end;
  end;

  if (FConfig = nil) or (FJSON <> JSON) then
  begin
    Config := ParseMusicStudioPsdConfig(JSON);
    FConfig.Free;
    FConfig := Config;
    FJSON := JSON;
  end;
end;

procedure TLipSyncScene.WaitForMusic;
begin
  // 書き出し時は解析の完了を待ち、初回と再描画で同じ結果を得る。
  if Assigned(FVoice) and not FVoice.Done then FVoice.WaitFor;
end;

function TLipSyncScene.MusicStatus: string;
begin
  case FMode of
    lmEnvelope:
      if not Assigned(FVoice) or not FVoice.Done then
        Result := '音声解析中'
      else if FVoice.ErrorText <> '' then
        Result := FVoice.ErrorText
      else
        Result := '簡易口パク（音量推定）';
    lmPhonemes:
      if FTrack < 0 then
        Result := FSinging.Message
      else
        Result := '音素口パク（歌詞トラックを自動選択）';
  else
    Result := '音楽ファイルを指定してください';
  end;
end;

function TLipSyncScene.MusicDuration: Double;
begin
  Result := 0;
  case FMode of
    lmEnvelope:
      if Assigned(FVoice) and FVoice.Done then Result := FVoice.Info.Duration;
    lmPhonemes: Result := FSinging.Duration;
  end;
end;

procedure LipSyncVolumeMouth(Peak, Threshold: Double; out Slot, SizeStep: Integer);
begin
  SizeStep := 0;
  if Peak>Threshold then
    SizeStep := EnsureRange(Ceil(High(LIP_SYNC_OPENING_SLOTS)*(Peak-Threshold)/(1-Threshold)),
      1,High(LIP_SYNC_OPENING_SLOTS));
  Slot := LIP_SYNC_OPENING_SLOTS[SizeStep];
end;

procedure TLipSyncScene.MouthAt(Seconds: Double; out Slot, SizeStep: Integer);
var
  Index, Count: Integer;
  Peak, Threshold: Double;
begin
  Slot := 0;
  SizeStep := High(LIP_SYNC_OPENING_SLOTS);
  if Seconds < 0 then Exit;
  case FMode of
    lmEnvelope:
      begin
        if not Assigned(FVoice) or not FVoice.Done then Exit;
        Count := Length(FVoice.Waveform);
        if (Count = 0) or (Seconds >= FVoice.Info.Duration) then Exit;
        Index := Min(Count - 1, Floor(Seconds * Count / FVoice.Info.Duration));
        Peak := Max(Abs(FVoice.Waveform[Index].Minimum), Abs(FVoice.Waveform[Index].Maximum));
        Threshold := LipSyncNumber(FConfig, 'threshold', 8, 0, 99) / 100;
        LipSyncVolumeMouth(Peak,Threshold,Slot,SizeStep);
      end;
    lmPhonemes:
      LipSyncSingingMouth(FSinging.Notes, FTrack, Seconds, Slot, SizeStep);
  end;
end;

{$POINTERMATH ON}
procedure FlipBitmap(Bitmap: TBitmap; Horizontal, Vertical: Boolean);
var
  Mirrored: TBitmap;
  Source, Target: PCardinal;
  X, Y, SY: Integer;
begin
  if not (Horizontal or Vertical) then Exit;
  Mirrored := TBitmap.Create;
  try
    Mirrored.PixelFormat := pf32bit;
    Mirrored.SetSize(Bitmap.Width, Bitmap.Height);
    Mirrored.AlphaFormat := afPremultiplied;
    for Y := 0 to Bitmap.Height - 1 do
    begin
      SY := Y;
      if Vertical then SY := Bitmap.Height - 1 - Y;
      Source := Bitmap.ScanLine[SY];
      Target := Mirrored.ScanLine[Y];
      if Horizontal then
        for X := 0 to Bitmap.Width - 1 do
          Target[X] := Source[Bitmap.Width - 1 - X]
      else
        Move(Source^, Target^, Bitmap.Width * SizeOf(Cardinal));
    end;
    Bitmap.Assign(Mirrored);
  finally
    Mirrored.Free;
  end;
end;

{$POINTERMATH OFF}
function LipSyncEyeLayer(Config: TJSONObject; Eye: TLipSyncEye): string;
begin
  Result := Config.GetValue<string>(EYE_KEYS[Eye],'');
end;

procedure AssignLipSyncEye(Config: TJSONObject; Eye: TLipSyncEye; const Key: string);
begin
  Config.RemovePair(EYE_KEYS[Eye]).Free;
  if Key<>'' then Config.AddPair(EYE_KEYS[Eye],Key);
end;

procedure LipSyncSampleMouth(Seconds, Speed: Double; out SongSlot, Opening: Integer);
const
  PHRASE: array[0..7] of Integer = (0,1,2,3,4,5,6,0);
var
  Position: Double;
begin
  Position := Frac(Max(0.0,Seconds)*Speed/LIP_SYNC_SAMPLE_SECONDS)*Length(PHRASE);
  SongSlot := PHRASE[Min(High(PHRASE),Floor(Position))];
  Opening := 0;
  if SongSlot<>0 then
    Opening := EnsureRange(Ceil(High(LIP_SYNC_OPENING_SLOTS)*Sin(Pi*Frac(Position))),1,High(LIP_SYNC_OPENING_SLOTS));
end;

function TLipSyncScene.EyeAt(Seconds: Double): TLipSyncEye;
var Phase: Double;
begin
  Phase := Frac((Max(0.0,Seconds)*LipSyncNumber(FConfig,'blinkSpeed',1,0.5,2)+2)/4)*4;
  if Phase<0.24 then
  begin
    if ((Phase<0.06) or (Phase>=0.17)) and
      FDocument.HasLayer(LipSyncEyeLayer(FConfig,leHalf)) then Exit(leHalf);
    if FDocument.HasLayer(LipSyncEyeLayer(FConfig,leClosed)) then Exit(leClosed);
  end;
  Result := leOpen;
end;

function TLipSyncScene.HasEyeAssignment: Boolean;
var Eye: TLipSyncEye;
begin
  if Assigned(FConfig) then
    for Eye := Low(Eye) to High(Eye) do
      if FDocument.HasLayer(LipSyncEyeLayer(FConfig,Eye)) then Exit(True);
  Result := False;
end;

procedure TLipSyncScene.ApplyEye(Overrides, Config: TJSONObject; Eye: TLipSyncEye);
var
  Other: TLipSyncEye;
  Key, OtherKey: string;
begin
  Key := LipSyncEyeLayer(Config,Eye);
  if (Eye=leHalf) and not FDocument.HasLayer(Key) then
    Key := LipSyncEyeLayer(Config,leClosed);
  if (Eye<>leOpen) and not FDocument.HasLayer(Key) then Exit;
  if FDocument.HasLayer(Key) and not FDocument.LayerBranchVisible(Key,Overrides) then Exit;
  for Other := Low(Other) to High(Other) do
  begin
    OtherKey := LipSyncEyeLayer(Config,Other);
    if FDocument.HasLayer(OtherKey) then MusicStudioSetJsonBoolean(Overrides,OtherKey,False);
  end;
  if FDocument.HasLayer(Key) then FDocument.SelectLayerOverride(Overrides,Key);
end;

function TLipSyncScene.Render(Bitmap: TBitmap; Seconds: Double; Slot: Integer;
  const PreviewLayer: string; FixedSizeStep: Integer; Expression: TJSONObject;
  BlinkSeconds: Double): Boolean;
var
  Config, Overrides, Visibility: TJSONObject;
  Pair: TJSONPair;
  Key, InactiveKey: string;
  Index, SizeStep: Integer;
  Eye: TLipSyncEye;
  PartScale: Double;
  Transform: TMusicStudioPsdTransform;
begin
  Result := False;
  if not FDocument.Loaded then Exit;
  SizeStep := FixedSizeStep;
  if Slot < 0 then MouthAt(Seconds, Slot, SizeStep);

  Config := ResolveMusicStudioMouthConfig(FDocument, FConfig);
  try
    if Expression <> nil then
    begin
      Visibility := MusicStudioPsdConfigObject(Config, 'visibility');
      for Pair in Expression do
        if Pair.JsonValue is TJSONBool then
          MusicStudioSetJsonBoolean(Visibility,Pair.JsonString.Value,TJSONBool(Pair.JsonValue).AsBoolean);
    end;
    if FDocument.HasLayer(PreviewLayer) then
      Key := PreviewLayer
    else if Slot <= 6 then
      Key := MusicStudioSelectedMouth(FDocument, Config, Slot)
    else
    begin
      Key := LipSyncLayer(Config, Slot);
      if (Slot=LIP_SYNC_OPENING_SLOTS[3]) and not FDocument.HasLayer(Key) then
        Key := LipSyncLayer(Config,LIP_SYNC_OPENING_SLOTS[2]);
      if not FDocument.HasLayer(Key) then Key := LipSyncLayer(Config,LIP_SYNC_OPENING_SLOTS[4]);
      if not FDocument.HasLayer(Key) then Key := MusicStudioSelectedMouth(FDocument, Config, 1);
    end;
    if not FDocument.HasLayer(Key) then
      Key := MusicStudioSelectedMouth(FDocument, Config, 0);

    Overrides := BuildMusicStudioPsdOverrides(FDocument, Config, 0);
    try
      if FDocument.HasLayer(Key) then
      begin
        for Index := 0 to High(LIP_SYNC_SLOT_NAMES) do
        begin
          if Index <= 6 then
            InactiveKey := MusicStudioSelectedMouth(FDocument, Config, Index)
          else
            InactiveKey := LipSyncLayer(Config, Index);
          if FDocument.HasLayer(InactiveKey) then
            MusicStudioSetJsonBoolean(Overrides, InactiveKey, False);
        end;
        FDocument.SelectLayerOverride(Overrides, Key);
      end;
      if HasEyeAssignment then
      begin
        if PreviewLayer='' then
        begin
          if BlinkSeconds<0 then BlinkSeconds := Seconds;
          ApplyEye(Overrides,Config,EyeAt(BlinkSeconds));
        end
        else
          for Eye := Low(Eye) to High(Eye) do
            if PreviewLayer=LipSyncEyeLayer(Config,Eye) then
            begin
              ApplyEye(Overrides,Config,Eye);
              Break;
            end;
      end;
      PartScale := 1;
      if (PreviewLayer = '') and (Slot > 0) and MusicStudioAnimateMouthSize(Config) then
        PartScale := MOUTH_SCALES[EnsureRange(SizeStep,Low(MOUTH_SCALES),High(MOUTH_SCALES))];
      Result := FDocument.Render(Bitmap, Overrides, 0, Key, PartScale);
      if Result then
      begin
        Transform := TransformFor(FDocument.Width, FDocument.Height);
        FlipBitmap(Bitmap, Transform.FlipX, Transform.FlipY);
      end;
    finally
      Overrides.Free;
    end;
  finally
    Config.Free;
  end;
end;

function TLipSyncScene.TransformFor(FrameWidth, FrameHeight: Integer): TMusicStudioPsdTransform;
var
  ErrorText: string;
  LegacyFit: Double;
begin
  if not ReadMusicStudioPsdTransform(FConfig.GetValue('transform'), Result, ErrorText) then
    raise EArgumentException.Create(ErrorText);
  if Result.HasStage then Exit;
  Result.HasStage := True;
  Result.Scale := 1;
  if Assigned(FConfig.GetValue('x')) or Assigned(FConfig.GetValue('y')) or
    Assigned(FConfig.GetValue('scale')) then
  begin
    // 旧版の画面百分率を、同じ表示位置・大きさのステージ座標へ変換する。
    Result.StageX := FrameWidth * (LipSyncNumber(FConfig, 'x', 50, -200, 300) - 50) / 100;
    Result.StageY := FrameHeight * (LipSyncNumber(FConfig, 'y', 50, -200, 300) - 50) / 100;
    if FDocument.Loaded then
    begin
      LegacyFit := Min(FrameWidth / FDocument.Width, FrameHeight / FDocument.Height);
      Result.Scale := EnsureRange(LegacyFit * LipSyncNumber(FConfig, 'scale', 100, 1, 500) / 100,
        0.001, 256.0);
    end;
  end;
end;

function TLipSyncScene.Placement(const Frame: TRect; OutputWidth, OutputHeight: Integer): TRect;
begin
  Result := Placement(Frame,OutputWidth,OutputHeight,TransformFor(OutputWidth,OutputHeight));
end;

function TLipSyncScene.Placement(const Frame: TRect; OutputWidth, OutputHeight: Integer;
  const Transform: TMusicStudioPsdTransform): TRect;
var
  Bounds: TRect;
begin
  if not FDocument.Loaded or (OutputWidth < 1) or (OutputHeight < 1) then Exit(TRect.Empty);
  Bounds := MusicStudioStageRect(Transform,
    FDocument.Width, FDocument.Height, OutputWidth, OutputHeight, TRect.Empty);
  Result := Rect(Frame.Left + Round(Bounds.Left * (Frame.Width / OutputWidth)),
    Frame.Top + Round(Bounds.Top * (Frame.Height / OutputHeight)),
    Frame.Left + Round(Bounds.Right * (Frame.Width / OutputWidth)),
    Frame.Top + Round(Bounds.Bottom * (Frame.Height / OutputHeight)));
end;

end.
