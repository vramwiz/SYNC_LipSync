unit SYNC_LipSync_Project;

// 統合編集と描画が共有するプロジェクトモデル。素材参照、歌唱と演出の区間、拍子表を保存する。

interface

uses
  System.JSON, System.Generics.Collections, Vcl.Graphics,
  SYNC_LipSync_Scene, SYNC_MusicStudio_BeatData, SYNC_MusicStudio_SingingData,
  SYNC_MusicStudio_AudioWaveform, SYNC_MusicStudio_PsdTransform, SYNC_MusicStudio_MotionData,
  SYNC_LipSync_Presentation;

type
  TLipSyncEffectLane = (elExpression, elMotion, elPresentation);

  TLipSyncEffect = class
  public
    Lane: TLipSyncEffectLane;
    StartBeat, EndBeat: Double;
    Visibility: TJSONObject; // 区間所有。PSDの基本表示に対する差分だけを持つ。
    Motion: TMusicStudioRhythmType;
    Presentation: TLipSyncPresentation;
    constructor Create(ALane: TLipSyncEffectLane; FirstBeat, LastBeat: Double);
    destructor Destroy; override;
  end;

  TLipSyncClip = class
  private
    procedure LoadSource(const FilePath: string; RequireReadable: Boolean);
  public
    Path: string;
    Beat, DurationSeconds: Double;
    Missing: Boolean;
    Source: TMusicStudioSingingSource;
    Track: Integer;
    constructor Create; overload;
    constructor Create(const FilePath: string; StartBeat: Double; RequireReadable: Boolean;
      StoredDuration: Double = 0); overload;
    // 新しい歌唱データを検証してから置き換える。配置と既知の長さは保持する。
    procedure ReplaceSource(const FilePath: string);
    // 呼出側所有のクリップを返す。読込済み音符は共有し、参照ファイルは読み直さない。
    function Duplicate(StartBeat: Double): TLipSyncClip;
  end;

  TLipSyncCharacter = class
  public
    PSDPath, Settings: string;
    PsdMissing: Boolean;
    // ここで所有する。リストから削除したクリップ・区間の参照は使えなくなる。
    Scene: TLipSyncScene;
    Clips: TObjectList<TLipSyncClip>;
    Effects: TObjectList<TLipSyncEffect>;
    MotionImage: TBitmap;
    Thumbnail: TBitmap;
    Threshold: Double;
    constructor Create(const Path, JSON: string);
    destructor Destroy; override;
    // 素材参照とPSD設定を更新し、次回の表示に備えて縮小画像を破棄する。
    procedure UpdateSettings(const Path, JSON: string);
    // 読込が成功したときだけPSDを差し替え、同じキーの差分と配置を引き継ぐ。
    procedure ReplacePSD(const Path: string);
    // 初回だけ生成する。Thumbnailはキャラクターが所有し、設定更新まで有効。
    procedure EnsureThumbnail;
    // 保存候補の配置だけを変更する。口差分の設定と縮小画像は保持する。
    procedure UpdatePlacement(const Transform: TMusicStudioPsdTransform);
    // 拍範囲と同じ行の重複を検証し、失敗時は元の区間を保持する。
    procedure SetEffectRange(Effect: TLipSyncEffect; FirstBeat, LastBeat: Double);
    function EffectAt(Lane: TLipSyncEffectLane; Beat: Double): TLipSyncEffect;
    function AddEffect(Lane: TLipSyncEffectLane; FirstBeat, LastBeat: Double): TLipSyncEffect;
    // 重複時は開始が後の歌唱を選ぶ。戻り値は借用で、Localは素材内の秒位置。
    function ActiveClip(const Timing: TMusicStudioTempoMap; Seconds: Double;
      out Local: Double): TLipSyncClip;
    // 指定時刻の合成用演出を返す。再生順序や過去のフレームに依存しない。
    function PresentationAt(const Timing: TMusicStudioTempoMap; Seconds: Double): TLipSyncPresentationFrame;
    // 呼出側のBitmapへ口差分・表情・変形を描く。登退場は合成側で適用する。
    function Render(Image: TBitmap; const Timing: TMusicStudioTempoMap;
      Audio: TMusicStudioWaveJob; Seconds: Double): Boolean;
  end;

  TLipSyncProject = class
  private
    FRoot: TJSONObject;
    FRelinkRevision: string;
    FAudioPath: string;
    FAudioMissing: Boolean;
    FAudio: TMusicStudioWaveJob;
    function GetAudio: TMusicStudioWaveJob;
  public
    Timing: TMusicStudioTempoMap;
    Characters: TObjectList<TLipSyncCharacter>;
    // 保存済みの統合形式を読み込む。旧形式ならAviUtl2の素材欄から1人分を復元する。
    constructor Create(const PSDPath, MusicPath, JSON: string);
    destructor Destroy; override;
    // 古い音声解析を終了し、新しい基準音源のワーカーをプロジェクトが所有する。
    procedure SetAudio(const Path: string);
    function EndBeat(Clip: TLipSyncClip): Double;
    function ContentEndBeat: Double;
    // 編集画面の定期確認用。欠損を検出しても参照パスや素材設定は変更しない。
    function CheckMissingAssets: Boolean;
    // 同一パスへの差し替えもホストの描画キャッシュへ通知する。
    procedure MarkRelink;
    // 元のJSONのうち統合編集部を置き換え、素材参照と設定の文字列を返す。
    function SaveJSON: string;
    property AudioPath: string read FAudioPath;
    property AudioMissing: Boolean read FAudioMissing;
    property Audio: TMusicStudioWaveJob read GetAudio;
  end;

function HasLipSyncArrangement(const JSON: string): Boolean;

implementation

uses
  System.SysUtils, System.Math, System.Types, SYNC_MusicStudio_PsdLayerConfig;

constructor TLipSyncEffect.Create(ALane: TLipSyncEffectLane; FirstBeat, LastBeat: Double);
begin
  inherited Create;
  if IsNan(FirstBeat) or IsInfinite(FirstBeat) or IsNan(LastBeat) or IsInfinite(LastBeat) or
    (FirstBeat < 0) or (LastBeat > 1000000) or (FirstBeat >= LastBeat) then
    raise EArgumentException.Create('区間の拍位置が不正です。');
  Lane := ALane;
  StartBeat := FirstBeat;
  EndBeat := LastBeat;
  Visibility := TJSONObject.Create;
end;

destructor TLipSyncEffect.Destroy;
begin
  Visibility.Free;
  inherited;
end;

function HasLipSyncArrangement(const JSON: string): Boolean;
var
  Value: TJSONValue;
begin
  Value := TJSONObject.ParseJSONValue(JSON);
  try
    Result := (Value is TJSONObject) and (TJSONObject(Value).GetValue('arrangement') is TJSONObject);
  finally
    Value.Free;
  end;
end;

constructor TLipSyncClip.Create;
begin
  inherited Create;
end;

constructor TLipSyncClip.Create(const FilePath: string; StartBeat: Double; RequireReadable: Boolean;
  StoredDuration: Double);
begin
  inherited Create;
  Beat := StartBeat;
  if IsNan(Beat) or IsInfinite(Beat) or (Beat < 0) or (Beat > 1000000) then
    raise EArgumentException.Create('クリップの拍位置が不正です。');
  if not IsNan(StoredDuration) and not IsInfinite(StoredDuration) and
    (StoredDuration>0) and (StoredDuration<=MUSICSTUDIO_MAX_MEDIA_SECONDS) then
    DurationSeconds := StoredDuration;
  LoadSource(FilePath,RequireReadable);
end;

procedure TLipSyncClip.LoadSource(const FilePath: string; RequireReadable: Boolean);
var Candidate: TMusicStudioSingingSource;
begin
  Candidate := LoadMusicStudioSinging(FilePath);
  if RequireReadable and not (Candidate.Status in [ssReady,ssNoLyrics]) then
    raise EArgumentException.Create(Candidate.Message);
  Path := FilePath;
  Source := Candidate;
  Missing := Candidate.Status=ssMissing;
  if DurationSeconds<=0 then DurationSeconds := Source.Duration;
  Track := LipSyncSingingTrack(Source);
end;

procedure TLipSyncClip.ReplaceSource(const FilePath: string);
begin
  LoadSource(FilePath,True);
end;

function TLipSyncClip.Duplicate(StartBeat: Double): TLipSyncClip;
begin
  Result := TLipSyncClip.Create;
  Result.Path := Path;
  Result.Beat := StartBeat;
  Result.DurationSeconds := DurationSeconds;
  Result.Missing := Missing;
  Result.Source := Source;
  Result.Track := Track;
end;

constructor TLipSyncCharacter.Create(const Path, JSON: string);
begin
  inherited Create;
  Clips := TObjectList<TLipSyncClip>.Create(True);
  Effects := TObjectList<TLipSyncEffect>.Create(True);
  Scene := TLipSyncScene.Create;
  UpdateSettings(Path, JSON);
end;

destructor TLipSyncCharacter.Destroy;
begin
  Thumbnail.Free;
  Scene.Free;
  Clips.Free;
  Effects.Free;
  MotionImage.Free;
  inherited;
end;

procedure TLipSyncCharacter.UpdateSettings(const Path, JSON: string);
var
  Config: TJSONObject;
begin
  Scene.Configure(Path, '', JSON);
  PSDPath := Path;
  PsdMissing := (Path<>'') and not FileExists(Path);
  Settings := JSON;
  FreeAndNil(Thumbnail);
  Config := TJSONObject.ParseJSONValue(JSON) as TJSONObject;
  try
    Threshold := 0.08;
    if Config <> nil then Threshold := LipSyncNumber(Config, 'threshold', 8, 0, 99) / 100;
  finally
    Config.Free;
  end;
end;

procedure TLipSyncCharacter.ReplacePSD(const Path: string);
var Candidate: TLipSyncScene;
begin
  Candidate := TLipSyncScene.Create;
  try
    Candidate.Configure(Path,'',Settings);
    if not Candidate.Document.Loaded then
      raise EArgumentException.Create(Candidate.Document.LastError);
    Scene.Free;
    Scene := Candidate;
    Candidate := nil;
    PSDPath := Path;
    PsdMissing := False;
    FreeAndNil(Thumbnail);
  finally
    Candidate.Free;
  end;
end;

procedure TLipSyncCharacter.UpdatePlacement(const Transform: TMusicStudioPsdTransform);
var
  Config: TJSONObject;
  Updated: string;
begin
  Config := ParseMusicStudioPsdConfig(Settings);
  try
    WriteMusicStudioPsdTransform(Config,Transform);
    Updated := Config.ToJSON;
    Scene.Configure(PSDPath,'',Updated);
    Settings := Updated;
  finally
    Config.Free;
  end;
end;

procedure TLipSyncCharacter.EnsureThumbnail;
var
  Image: TBitmap;
  Scale: Double;
begin
  if Assigned(Thumbnail) then Exit;
  Thumbnail := TBitmap.Create;
  Image := TBitmap.Create;
  try
    if not Scene.Render(Image, 0, 0) then Exit;
    Scale := Min(1.0, 160 / Max(Image.Width, Image.Height));
    Thumbnail.SetSize(Max(1, Round(Image.Width*Scale)), Max(1, Round(Image.Height*Scale)));
    Thumbnail.Canvas.Brush.Color := TColor($002D2D2D);
    Thumbnail.Canvas.FillRect(Rect(0,0,Thumbnail.Width,Thumbnail.Height));
    Thumbnail.Canvas.StretchDraw(Rect(0,0,Thumbnail.Width,Thumbnail.Height),Image);
  finally
    Image.Free;
  end;
end;

function TLipSyncCharacter.EffectAt(Lane: TLipSyncEffectLane; Beat: Double): TLipSyncEffect;
var Effect: TLipSyncEffect;
begin
  for Effect in Effects do
    if (Effect.Lane = Lane) and (Beat >= Effect.StartBeat) and (Beat < Effect.EndBeat) then
      Exit(Effect);
  Result := nil;
end;

procedure TLipSyncCharacter.SetEffectRange(Effect: TLipSyncEffect; FirstBeat, LastBeat: Double);
var
  Other: TLipSyncEffect;
begin
  if IsNan(FirstBeat) or IsInfinite(FirstBeat) or IsNan(LastBeat) or IsInfinite(LastBeat) or
    (FirstBeat < 0) or (LastBeat > 1000000) or (FirstBeat >= LastBeat) then
    raise EArgumentException.Create('区間の拍位置が不正です。');
  for Other in Effects do
    if (Other<>Effect) and (Other.Lane=Effect.Lane) and
      (MusicStudioComparePositions(FirstBeat,Other.EndBeat)<0) and
      (MusicStudioComparePositions(LastBeat,Other.StartBeat)>0) then
      raise EArgumentException.Create('同じ行の区間とは重ねられません。');
  Effect.StartBeat := FirstBeat;
  Effect.EndBeat := LastBeat;
end;

function TLipSyncCharacter.AddEffect(Lane: TLipSyncEffectLane;
  FirstBeat, LastBeat: Double): TLipSyncEffect;
begin
  Result := TLipSyncEffect.Create(Lane,FirstBeat,LastBeat);
  try
    SetEffectRange(Result,FirstBeat,LastBeat);
    Effects.Add(Result);
  except
    Result.Free;
    raise;
  end;
end;

function TLipSyncCharacter.ActiveClip(const Timing: TMusicStudioTempoMap;
  Seconds: Double; out Local: Double): TLipSyncClip;
var
  Clip: TLipSyncClip;
  Start: Double;
begin
  Result := nil;
  Local := 0;
  for Clip in Clips do
  begin
    Start := Timing.BeatToSeconds(Clip.Beat);
    if (Seconds >= Start) and (Seconds < Start + Clip.DurationSeconds) and
      ((Result = nil) or (Clip.Beat >= Result.Beat)) then
    begin
      Result := Clip;
      Local := Seconds - Start;
    end;
  end;
end;

function TLipSyncCharacter.PresentationAt(const Timing: TMusicStudioTempoMap;
  Seconds: Double): TLipSyncPresentationFrame;
var
  Effect, First, Previous: TLipSyncEffect;
  StartTime, EndTime, Progress: Double;
begin
  First := nil;
  Previous := nil;
  for Effect in Effects do
    if (Effect.Lane = elPresentation) and (Effect.Presentation <> lpNone) then
    begin
      if (First = nil) or (Effect.StartBeat < First.StartBeat) then First := Effect;
      StartTime := Timing.BeatToSeconds(Effect.StartBeat);
      if (StartTime <= Seconds) and
        ((Previous = nil) or (Effect.StartBeat > Previous.StartBeat)) then Previous := Effect;
    end;

  // 最初の登場より前と、退場完了から次の登場までは非表示。
  if Previous = nil then
  begin
    Result := LipSyncPresentationFrame(lpNone,0);
    if Assigned(First) and LipSyncPresentationIsEntrance(First.Presentation) then Result.Opacity := 0;
    Exit;
  end;
  StartTime := Timing.BeatToSeconds(Previous.StartBeat);
  EndTime := Timing.BeatToSeconds(Previous.EndBeat);
  if (Seconds>=EndTime) or (EndTime<=StartTime) then
  begin
    Result := LipSyncPresentationFrame(lpNone,0);
    if not LipSyncPresentationIsEntrance(Previous.Presentation) then Result.Opacity := 0;
    Exit;
  end;
  Progress := (Seconds-StartTime)/(EndTime-StartTime);
  Result := LipSyncPresentationFrame(Previous.Presentation,Progress);
end;

function TLipSyncCharacter.Render(Image: TBitmap; const Timing: TMusicStudioTempoMap;
  Audio: TMusicStudioWaveJob; Seconds: Double): Boolean;
var
  Clip: TLipSyncClip;
  Local, Peak, Beat: Double;
  Slot, Step, Index, Count: Integer;
  Effect: TLipSyncEffect;
  Visibility: TJSONObject;
  Motion: TMusicStudioMotionTransform;
begin
  if PsdMissing then Exit(False);
  Slot := 0;
  Step := High(LIP_SYNC_OPENING_SLOTS);
  Clip := ActiveClip(Timing, Seconds, Local);
  if Clip <> nil then
  begin
    if not Clip.Missing then LipSyncSingingMouth(Clip.Source.Notes,Clip.Track,Local,Slot,Step);
  end
  else if (Clips.Count = 0) and Assigned(Audio) and Audio.Done and
    (Seconds >= 0) and (Seconds < Audio.Info.Duration) then
  begin
    Count := Length(Audio.Waveform);
    if Count > 0 then
    begin
      Index := Min(Count - 1, Floor(Seconds * Count / Audio.Info.Duration));
      Peak := Max(Abs(Audio.Waveform[Index].Minimum), Abs(Audio.Waveform[Index].Maximum));
      LipSyncVolumeMouth(Peak,Threshold,Slot,Step);
    end;
  end;
  Beat := Timing.SecondsToBeat(Max(0.0,Seconds));
  Visibility := nil;
  Effect := EffectAt(elExpression,Beat);
  if Assigned(Effect) then Visibility := Effect.Visibility;
  Result := Scene.Render(Image,Seconds,Slot,'',Step,Visibility);
  if not Result then Exit;
  Effect := EffectAt(elMotion,Beat);
  if Assigned(Effect) and (Effect.Motion <> rmtNone) then
  begin
    CalculateMusicStudioRhythmTransform(Effect.Motion,Beat-Effect.StartBeat,1,24,Motion);
    if (Motion.OffsetX = 0) and (Motion.OffsetY = 0) and (Motion.Scale = 1) and
      (Motion.VerticalScale = 1) and (Motion.TopOffsetX = 0) and
      (Motion.AngleDegrees = 0) then Exit;
    if MotionImage = nil then MotionImage := TBitmap.Create;
    RenderMusicStudioMotion(Image,MotionImage,Motion);
    Image.Assign(MotionImage);
  end;
end;

constructor TLipSyncProject.Create(const PSDPath, MusicPath, JSON: string);
var
  RootValue, Value, TrackValue, ClipValue, EffectValue, Visibility: TJSONValue;
  Arrangement, TrackObj, ClipObj, EffectObj: TJSONObject;
  Character: TLipSyncCharacter;
  Effect: TLipSyncEffect;
  Lane: TLipSyncEffectLane;
  Motion: TMusicStudioRhythmType;
  Presentation: TLipSyncPresentation;
begin
  inherited Create;
  Timing := TMusicStudioTempoMap.Create;
  Characters := TObjectList<TLipSyncCharacter>.Create(True);
  RootValue := TJSONObject.ParseJSONValue(JSON);
  if RootValue is TJSONObject then FRoot := TJSONObject(RootValue)
  else
  begin
    RootValue.Free;
    FRoot := TJSONObject.Create;
  end;

  Value := FRoot.GetValue('arrangement');
  if not (Value is TJSONObject) then
  begin
    if LipSyncMode(MusicPath) = lmEnvelope then SetAudio(MusicPath);
    if PSDPath <> '' then
    begin
      Character := TLipSyncCharacter.Create(PSDPath, FRoot.ToJSON);
      Characters.Add(Character);
      if LipSyncMode(MusicPath) = lmPhonemes then
        Character.Clips.Add(TLipSyncClip.Create(MusicPath, 0, False));
    end;
    Exit;
  end;

  Arrangement := TJSONObject(Value);
  FRelinkRevision := Arrangement.GetValue<string>('relinkRevision','');
  SetAudio(Arrangement.GetValue<string>('audio', ''));
  Value := Arrangement.GetValue('timing');
  if Value is TJSONObject then Timing.LoadJSON(TJSONObject(Value));
  Value := Arrangement.GetValue('characters');
  if not (Value is TJSONArray) then Exit;
  for TrackValue in TJSONArray(Value) do
    if TrackValue is TJSONObject then
    begin
      TrackObj := TJSONObject(TrackValue);
      Character := TLipSyncCharacter.Create(TrackObj.GetValue<string>('psd', ''),
        TrackObj.GetValue<string>('settings', '{}'));
      Characters.Add(Character);
      if TrackObj.GetValue('clips') is TJSONArray then
        for ClipValue in TJSONArray(TrackObj.GetValue('clips')) do
          if ClipValue is TJSONObject then
          begin
            ClipObj := TJSONObject(ClipValue);
            Character.Clips.Add(TLipSyncClip.Create(ClipObj.GetValue<string>('path', ''),
              ClipObj.GetValue<Double>('beat',0),False,ClipObj.GetValue<Double>('duration',0)));
          end;
      if TrackObj.GetValue('effects') is TJSONArray then
        for EffectValue in TJSONArray(TrackObj.GetValue('effects')) do
          if EffectValue is TJSONObject then
          begin
            EffectObj := TJSONObject(EffectValue);
            Lane := elExpression;
            if EffectObj.GetValue<string>('lane','') = 'motion' then Lane := elMotion;
            if EffectObj.GetValue<string>('lane','') = 'presentation' then Lane := elPresentation;
            Effect := Character.AddEffect(Lane,EffectObj.GetValue<Double>('start',0),
              EffectObj.GetValue<Double>('end',0));
            Visibility := EffectObj.GetValue('visibility');
            if Visibility is TJSONObject then
            begin
              Effect.Visibility.Free;
              Effect.Visibility := TJSONObject(Visibility.Clone);
            end;
            for Motion := Low(Motion) to High(Motion) do
              if MusicStudioRhythmKey(Motion) = EffectObj.GetValue<string>('motion','') then
                Effect.Motion := Motion;
            for Presentation := Low(Presentation) to High(Presentation) do
              if LipSyncPresentationKey(Presentation) = EffectObj.GetValue<string>('cue','') then
                Effect.Presentation := Presentation;
          end;
    end;
end;

destructor TLipSyncProject.Destroy;
begin
  FAudio.Free;
  Characters.Free;
  Timing.Free;
  FRoot.Free;
  inherited;
end;

function TLipSyncProject.GetAudio: TMusicStudioWaveJob;
begin
  if FAudioMissing then Exit(nil);
  Result := FAudio;
end;

procedure TLipSyncProject.SetAudio(const Path: string);
begin
  if (Path = FAudioPath) and not FAudioMissing then Exit;
  if (Path <> '') and (LipSyncMode(Path) <> lmEnvelope) then
    raise EArgumentException.Create('基準音源には WAV または MP3 を指定してください。');
  FreeAndNil(FAudio);
  FAudioPath := Path;
  FAudioMissing := (Path<>'') and not FileExists(Path);
  if (Path<>'') and not FAudioMissing then
  begin
    FAudio := TMusicStudioWaveJob.Create(Path, 0);
    FAudio.Start;
  end;
end;

function TLipSyncProject.EndBeat(Clip: TLipSyncClip): Double;
begin
  Result := Max(Clip.Beat + 1/4,
    Timing.SecondsToBeat(Timing.BeatToSeconds(Clip.Beat) + Clip.DurationSeconds));
end;

function TLipSyncProject.ContentEndBeat: Double;
var
  Character: TLipSyncCharacter;
  Clip: TLipSyncClip;
  Effect: TLipSyncEffect;
begin
  Result := 0;
  for Character in Characters do
  begin
    for Clip in Character.Clips do Result := Max(Result,EndBeat(Clip));
    for Effect in Character.Effects do Result := Max(Result,Effect.EndBeat);
  end;
end;

function TLipSyncProject.CheckMissingAssets: Boolean;
var
  Character: TLipSyncCharacter;
  Clip: TLipSyncClip;
begin
  Result := False;
  if not FAudioMissing and (FAudioPath<>'') and not FileExists(FAudioPath) then
  begin
    FAudioMissing := True;
    Result := True;
  end;
  for Character in Characters do
  begin
    if not Character.PsdMissing and (Character.PSDPath<>'') and not FileExists(Character.PSDPath) then
    begin
      Character.PsdMissing := True;
      Result := True;
    end;
    for Clip in Character.Clips do
      if not Clip.Missing and (Clip.Path<>'') and not FileExists(Clip.Path) then
      begin
        Clip.Missing := True;
        Result := True;
      end;
  end;
end;

procedure TLipSyncProject.MarkRelink;
var Revision: TGUID;
begin
  if CreateGUID(Revision)=0 then FRelinkRevision := GUIDToString(Revision);
end;

function TLipSyncProject.SaveJSON: string;
var
  Arrangement, TrackObj, ClipObj, EffectObj: TJSONObject;
  Tracks, Clips, Effects: TJSONArray;
  Character: TLipSyncCharacter;
  Clip: TLipSyncClip;
  Effect: TLipSyncEffect;
begin
  Arrangement := TJSONObject.Create;
  FRoot.RemovePair('arrangement').Free;
  FRoot.AddPair('arrangement', Arrangement);
  Arrangement.AddPair('audio', FAudioPath);
  if FRelinkRevision<>'' then Arrangement.AddPair('relinkRevision',FRelinkRevision);
  Arrangement.AddPair('timing', TJSONObject.ParseJSONValue(Timing.TimingJSON));
  Tracks := TJSONArray.Create;
  Arrangement.AddPair('characters', Tracks);
  for Character in Characters do
  begin
    TrackObj := TJSONObject.Create;
    Tracks.AddElement(TrackObj);
    TrackObj.AddPair('psd', Character.PSDPath);
    TrackObj.AddPair('settings', Character.Settings);
    Clips := TJSONArray.Create;
    TrackObj.AddPair('clips', Clips);
    for Clip in Character.Clips do
    begin
      ClipObj := TJSONObject.Create;
      Clips.AddElement(ClipObj);
      ClipObj.AddPair('path', Clip.Path);
      ClipObj.AddPair('beat', TJSONNumber.Create(Clip.Beat));
      if Clip.DurationSeconds>0 then ClipObj.AddPair('duration',TJSONNumber.Create(Clip.DurationSeconds));
    end;
    Effects := TJSONArray.Create;
    TrackObj.AddPair('effects',Effects);
    for Effect in Character.Effects do
    begin
      EffectObj := TJSONObject.Create;
      Effects.AddElement(EffectObj);
      EffectObj.AddPair('start',TJSONNumber.Create(Effect.StartBeat));
      EffectObj.AddPair('end',TJSONNumber.Create(Effect.EndBeat));
      if Effect.Lane = elPresentation then
      begin
        EffectObj.AddPair('lane','presentation');
        EffectObj.AddPair('cue',LipSyncPresentationKey(Effect.Presentation));
      end
      else if Effect.Lane = elMotion then
      begin
        EffectObj.AddPair('lane','motion');
        EffectObj.AddPair('motion',MusicStudioRhythmKey(Effect.Motion));
      end
      else
      begin
        EffectObj.AddPair('lane','expression');
        EffectObj.AddPair('visibility',TJSONObject(Effect.Visibility.Clone));
      end;
    end;
  end;
  Result := FRoot.ToJSON;
end;

end.

