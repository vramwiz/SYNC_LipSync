unit SYNC_MusicStudio_MotionData;

// PSDに共有する拍基準の変形設定と無音の画像処理。
// SYNC_Motion_TempoMotionのリズム曲線・逆変換をコピーして適応した。
// ファイルI/O、音声、楽譜解析、AviUtl2のSDKには依存しない。
interface

uses System.JSON, Vcl.Graphics;

type
  TMusicStudioRhythmType = (rmtNone, rmtVerticalJump, rmtShrink,
    rmtBounce, rmtStep, rmtPendulum, rmtPendulumTwoBeat);
  TMusicStudioMotionTransform = record
    OffsetX, OffsetY: Integer;
    Scale, VerticalScale, AngleDegrees, TopOffsetX: Double;
    WaistRatio, JointFlexibility: Double;
  end;

  TMusicStudioMotionConfig = class
  private
    FOriginal: TJSONObject;
  public
    RhythmType: TMusicStudioRhythmType;
    Strength, Speed, Param1, Param2, ShiftBeats: Double;
    OffsetX, OffsetY, ScalePercent, RotationDegrees: Double;
    constructor Create;
    destructor Destroy; override;
    // 読込に失敗した場合は例外。呼出側は直前の設定を保持できる。
    procedure LoadJSON(const Text: string);
    function ToJSON: string;
    procedure Validate;
  end;

function MusicStudioRhythmKey(Value: TMusicStudioRhythmType): string;
function MusicStudioRhythmCaption(Value: TMusicStudioRhythmType): string;
procedure CalculateMusicStudioRhythmTransform(MotionType: TMusicStudioRhythmType;
  BeatPosition, Speed, Strength: Double; out Transform: TMusicStudioMotionTransform;
  Param1: Double = 50.0; Param2: Double = 50.0);
procedure CalculateMusicStudioMotionTransform(Config: TMusicStudioMotionConfig;
  BeatPosition: Double; out Transform: TMusicStudioMotionTransform);
// Sourceは変更しない。Destは呼出側所有。透過BGRAをそのまま逆変換する。
// 同じキャンバス内で変形するため、移動先が画像外の場合は透明となる。
procedure RenderMusicStudioMotion(Source, Dest: TBitmap;
  const Transform: TMusicStudioMotionTransform);

implementation

uses System.SysUtils, System.Math, System.Types;

type
  TPixelBGRA = packed record B, G, R, A: Byte; end;
  TPixelRow = array[0..MaxInt div SizeOf(TPixelBGRA)-1] of TPixelBGRA;
  PPixelRow = ^TPixelRow;

function MusicStudioRhythmKey(Value: TMusicStudioRhythmType): string;
const Keys: array[TMusicStudioRhythmType] of string =
  ('none','verticalJump','shrink','bounce','step','pendulum','pendulumTwoBeat');
begin Result := Keys[Value]; end;

function MusicStudioRhythmCaption(Value: TMusicStudioRhythmType): string;
const Captions: array[TMusicStudioRhythmType] of string =
  ('なし','縦ジャンプ','縮小','バウンス','ステップ','振り子（1拍）','振り子（2拍）');
begin Result := Captions[Value]; end;

function RhythmFromKey(const Key: string): TMusicStudioRhythmType;
var Value: TMusicStudioRhythmType;
begin
  for Value := Low(Value) to High(Value) do
    if Key = MusicStudioRhythmKey(Value) then Exit(Value);
  raise EArgumentException.Create('未対応のアニメーション種類: ' + Key);
end;

procedure ReplacePair(Obj: TJSONObject; const Key: string; Value: TJSONValue);
begin Obj.RemovePair(Key).Free; Obj.AddPair(Key,Value); end;

function ObjectAt(Obj: TJSONObject; const Key: string): TJSONObject;
var Value: TJSONValue;
begin
  Value := Obj.GetValue(Key);
  if Value = nil then Exit(nil);
  if not (Value is TJSONObject) then
    raise EArgumentException.Create(Key + ' はオブジェクトで指定してください。');
  Result := TJSONObject(Value);
end;

function NumberAt(Obj: TJSONObject; const Key: string; Default: Double): Double;
var Value: TJSONValue;
begin
  if Obj = nil then Exit(Default);
  Value := Obj.GetValue(Key);
  if Value = nil then Exit(Default);
  if not (Value is TJSONNumber) then
    raise EArgumentException.Create(Key + ' は数値で指定してください。');
  Result := TJSONNumber(Value).AsDouble;
end;

procedure RequireRange(Value, LowValue, HighValue: Double; const Name: string);
begin
  if IsNan(Value) or IsInfinite(Value) or (Value < LowValue) or (Value > HighValue) then
    raise EArgumentException.Create(Name + ' の値が範囲外です。');
end;

constructor TMusicStudioMotionConfig.Create;
begin
  inherited;
  FOriginal := TJSONObject.Create;
  RhythmType := rmtNone;
  Strength := 50; Speed := 2; Param1 := 50; Param2 := 50;
  ScalePercent := 100;
end;

destructor TMusicStudioMotionConfig.Destroy;
begin FOriginal.Free; inherited; end;

procedure TMusicStudioMotionConfig.Validate;
begin
  if (Ord(RhythmType) < Ord(Low(TMusicStudioRhythmType))) or
    (Ord(RhythmType) > Ord(High(TMusicStudioRhythmType))) then
    raise EArgumentException.Create('アニメーション種類が不正です。');
  RequireRange(Strength,-100,100,'強さ'); RequireRange(Speed,1,100,'速さ');
  RequireRange(Param1,0,100,'腰位置'); RequireRange(Param2,0,100,'柔らかさ');
  RequireRange(ShiftBeats,-1024,1024,'拍ずらし');
  RequireRange(OffsetX,-10000,10000,'X移動'); RequireRange(OffsetY,-10000,10000,'Y移動');
  RequireRange(ScalePercent,1,400,'拡大率'); RequireRange(RotationDegrees,-360,360,'回転');
end;

procedure TMusicStudioMotionConfig.LoadJSON(const Text: string);
var Parsed: TJSONValue; Root, Rhythm, Static: TJSONObject;
  Candidate: TMusicStudioMotionConfig; KindValue: TJSONValue;
begin
  if Trim(Text) = '' then Parsed := TJSONObject.Create
  else Parsed := TJSONObject.ParseJSONValue(Text);
  Candidate := nil;
  try
    if not (Parsed is TJSONObject) then
      raise EArgumentException.Create('アニメーション設定JSONが不正です。');
    Root := TJSONObject(Parsed);
    if NumberAt(Root,'version',1) <> 1 then
      raise EArgumentException.Create('未対応のアニメーション設定バージョンです。');
    Rhythm := ObjectAt(Root,'rhythm'); Static := ObjectAt(Root,'transform');
    Candidate := TMusicStudioMotionConfig.Create;
    if Rhythm <> nil then begin
      KindValue := Rhythm.GetValue('type');
      if KindValue <> nil then begin
        if not (KindValue is TJSONString) then
          raise EArgumentException.Create('アニメーション種類は文字列で指定してください。');
        Candidate.RhythmType := RhythmFromKey(KindValue.Value);
      end;
    end;
    Candidate.Strength := NumberAt(Rhythm,'strength',50);
    Candidate.Speed := NumberAt(Rhythm,'speed',2);
    Candidate.Param1 := NumberAt(Rhythm,'param1',50);
    Candidate.Param2 := NumberAt(Rhythm,'param2',50);
    Candidate.ShiftBeats := NumberAt(Rhythm,'shiftBeats',0);
    Candidate.OffsetX := NumberAt(Static,'x',0);
    Candidate.OffsetY := NumberAt(Static,'y',0);
    Candidate.ScalePercent := NumberAt(Static,'scalePercent',100);
    Candidate.RotationDegrees := NumberAt(Static,'rotationDegrees',0);
    Candidate.Validate;
    RhythmType := Candidate.RhythmType; Strength := Candidate.Strength;
    Speed := Candidate.Speed; Param1 := Candidate.Param1; Param2 := Candidate.Param2;
    ShiftBeats := Candidate.ShiftBeats; OffsetX := Candidate.OffsetX; OffsetY := Candidate.OffsetY;
    ScalePercent := Candidate.ScalePercent; RotationDegrees := Candidate.RotationDegrees;
    FOriginal.Free; FOriginal := TJSONObject(Root.Clone);
  finally Candidate.Free; Parsed.Free; end;
end;

function TMusicStudioMotionConfig.ToJSON: string;
var Root, Rhythm, Static: TJSONObject;
begin
  Validate;
  Root := TJSONObject(FOriginal.Clone);
  try
    Rhythm := ObjectAt(Root,'rhythm');
    if Rhythm = nil then begin Rhythm := TJSONObject.Create; Root.AddPair('rhythm',Rhythm); end;
    Static := ObjectAt(Root,'transform');
    if Static = nil then begin Static := TJSONObject.Create; Root.AddPair('transform',Static); end;
    ReplacePair(Root,'version',TJSONNumber.Create(1));
    ReplacePair(Rhythm,'type',TJSONString.Create(MusicStudioRhythmKey(RhythmType)));
    ReplacePair(Rhythm,'strength',TJSONNumber.Create(Strength));
    ReplacePair(Rhythm,'speed',TJSONNumber.Create(Speed));
    ReplacePair(Rhythm,'param1',TJSONNumber.Create(Param1));
    ReplacePair(Rhythm,'param2',TJSONNumber.Create(Param2));
    ReplacePair(Rhythm,'shiftBeats',TJSONNumber.Create(ShiftBeats));
    ReplacePair(Static,'x',TJSONNumber.Create(OffsetX));
    ReplacePair(Static,'y',TJSONNumber.Create(OffsetY));
    ReplacePair(Static,'scalePercent',TJSONNumber.Create(ScalePercent));
    ReplacePair(Static,'rotationDegrees',TJSONNumber.Create(RotationDegrees));
    Result := Root.ToJSON;
  finally Root.Free; end;
end;

function SmoothStep(Value: Double): Double;
begin Value := EnsureRange(Value,0.0,1.0); Result := Value*Value*(3.0-2.0*Value); end;

function JumpCurve(Progress: Double): Double;
begin
  Progress := EnsureRange(Progress,0.0,1.0);
  if Progress < 0.15 then Result := 0.08*SmoothStep(Progress/0.15)
  else if Progress < 0.45 then Result := 0.08-1.08*SmoothStep((Progress-0.15)/0.30)
  else if Progress < 0.58 then Result := -1.0
  else if Progress < 0.85 then Result := -1.0+1.06*SmoothStep((Progress-0.58)/0.27)
  else Result := 0.06*(1.0-SmoothStep((Progress-0.85)/0.15));
end;

function TwoBeatSwing(BeatPosition, Speed: Double): Double;
var Phase: Double;
begin
  Phase := BeatPosition*Speed; Phase := Phase-Floor(Phase/4.0)*4.0;
  if Phase < 1 then Result := -Cos(Phase*Pi)
  else if Phase < 2 then Result := 1
  else if Phase < 3 then Result := Cos((Phase-2.0)*Pi)
  else Result := -1;
end;

procedure CalculateMusicStudioRhythmTransform(MotionType: TMusicStudioRhythmType;
  BeatPosition, Speed, Strength: Double; out Transform: TMusicStudioMotionTransform;
  Param1, Param2: Double);
var Curve, Progress, Swing, Phase, Duration: Double;
begin
  Transform.OffsetX := 0; Transform.OffsetY := 0; Transform.Scale := 1;
  Transform.VerticalScale := 1; Transform.AngleDegrees := 0; Transform.TopOffsetX := 0;
  Transform.WaistRatio := 0.475; Transform.JointFlexibility := 0.5;
  if IsNan(BeatPosition) or IsInfinite(BeatPosition) or IsNan(Speed) or
    IsInfinite(Speed) or IsNan(Strength) or IsInfinite(Strength) then Exit;
  if (MotionType = rmtNone) or SameValue(Strength,0) or (Speed <= 0) then Exit;
  if MotionType = rmtBounce then begin
    Progress := BeatPosition*Speed/2.0; Curve := Sqr(Sin(Progress*Pi));
    Transform.OffsetY := -Round(Strength*0.25*Curve);
    Transform.VerticalScale := EnsureRange(1.0-Abs(Strength)/500.0*(1.0-Curve)+
      Abs(Strength)/1250.0*Curve,0.5,1.5); Exit;
  end;
  if MotionType = rmtStep then begin
    Progress := BeatPosition*Speed/2.0; Swing := -Cos(Progress*Pi);
    Transform.OffsetX := Round(Strength*Swing);
    Transform.OffsetY := -Round(Abs(Strength)*0.2*Abs(Sin(Progress*Pi)));
    Transform.TopOffsetX := -Strength*Swing;
  end else if MotionType in [rmtPendulum,rmtPendulumTwoBeat] then begin
    if MotionType = rmtPendulumTwoBeat then Swing := TwoBeatSwing(BeatPosition,Speed)
    else Swing := Sin(BeatPosition*Speed*Pi);
    Transform.TopOffsetX := Strength*Swing;
  end else begin
    Phase := BeatPosition-Floor(BeatPosition);
    if MotionType = rmtVerticalJump then Duration := Min(1.0,2.0/Speed)
    else Duration := 1.0/Speed;
    if Phase >= Duration then Exit;
    Progress := Phase/Duration;
    case MotionType of
      rmtVerticalJump: Transform.OffsetY := Round(Strength*JumpCurve(Progress));
      rmtShrink: Transform.Scale := 1.0-Strength*4.0*Progress*(1.0-Progress)/400.0;
    end;
  end;
  Transform.WaistRatio := 0.35+EnsureRange(Param1,0.0,100.0)*0.0025;
  Transform.JointFlexibility := EnsureRange(Param2,0.0,100.0)/100.0;
end;

procedure CalculateMusicStudioMotionTransform(Config: TMusicStudioMotionConfig;
  BeatPosition: Double; out Transform: TMusicStudioMotionTransform);
begin
  if Config = nil then raise EArgumentNilException.Create('Config');
  Config.Validate;
  CalculateMusicStudioRhythmTransform(Config.RhythmType,BeatPosition-Config.ShiftBeats,
    Config.Speed,Config.Strength,Transform,Config.Param1,Config.Param2);
  Inc(Transform.OffsetX,Round(Config.OffsetX)); Inc(Transform.OffsetY,Round(Config.OffsetY));
  Transform.Scale := Transform.Scale*Config.ScalePercent/100.0;
  Transform.AngleDegrees := Config.RotationDegrees;
end;

function PendulumWeight(HeightRatio, WaistRatio, Flexibility: Double): Double;
var NeckRatio, Segmented: Double;
begin
  HeightRatio := EnsureRange(HeightRatio,0.0,1.0);
  WaistRatio := EnsureRange(WaistRatio,0.2,0.75); Flexibility := EnsureRange(Flexibility,0.0,1.0);
  NeckRatio := Min(0.9,WaistRatio+0.3);
  if HeightRatio <= WaistRatio then Segmented := 0.35*SmoothStep(HeightRatio/WaistRatio)
  else if HeightRatio < NeckRatio then Segmented := 0.35+0.65*
    SmoothStep((HeightRatio-WaistRatio)/(NeckRatio-WaistRatio))
  else Segmented := 1;
  Result := HeightRatio+(Segmented-HeightRatio)*Flexibility;
end;

procedure RenderMusicStudioMotion(Source, Dest: TBitmap;
  const Transform: TMusicStudioMotionTransform);
var Working: TBitmap; X,Y,SX,SY,W,H: Integer; Row: PPixelRow;
  SourceRows: TArray<PPixelRow>; Opaque: Boolean;
  CX,CY,Bottom,CosA,SinA,InverseScale,DX,DY,PX,PY,HeightRatio: Double;
  procedure RenderUnrotated;
  var RowShear: Double; Left,Right,Count,X,Y: Integer;
  begin
    // Without rotation the source Y and articulated shear are constant across each output row.
    // Pure bounce/jump additionally copies a complete row span, preserving nearest-neighbour pixels.
    Left := Max(0,-Transform.OffsetX); Right := Min(W,W-Transform.OffsetX); Count := Max(0,Right-Left);
    for Y := 0 to H-1 do begin
      Row := Dest.ScanLine[Y]; FillChar(Row^,NativeUInt(W)*SizeOf(TPixelBGRA),0);
      DY := Y-CY-Transform.OffsetY; PY := CY+DY*InverseScale;
      RowShear := 0;
      if H>1 then begin
        PY := Bottom+(PY-Bottom)/Transform.VerticalScale;
        if Transform.TopOffsetX<>0 then begin
          HeightRatio := EnsureRange((H-1-PY)/(H-1),0.0,1.0);
          RowShear := Transform.TopOffsetX*PendulumWeight(HeightRatio,Transform.WaistRatio,Transform.JointFlexibility);
        end;
      end;
      SY := Round(PY); if (SY<0) or (SY>=H) then Continue;
      if (Transform.Scale=1) and (Transform.TopOffsetX=0) then begin
        if Count>0 then begin
          Move(SourceRows[SY]^[Left],Row[Left+Transform.OffsetX],Count*SizeOf(TPixelBGRA));
          if Opaque then for X := Left+Transform.OffsetX to Right+Transform.OffsetX-1 do Row[X].A := 255;
        end;
        Continue;
      end;
      for X := 0 to W-1 do begin
        DX := X-CX-Transform.OffsetX; PX := CX+DX*InverseScale-RowShear; SX := Round(PX);
        if (SX>=0) and (SX<W) then begin Row[X] := SourceRows[SY]^[SX]; if Opaque then Row[X].A := 255; end;
      end;
    end;
  end;
begin
  if (Source = nil) or (Dest = nil) then raise EArgumentNilException.Create('Bitmap');
  if Source = Dest then raise EArgumentException.Create('SourceとDestは別の画像にしてください。');
  if (Transform.Scale <= 0) or (Transform.VerticalScale <= 0) or
    IsNan(Transform.Scale) or IsInfinite(Transform.Scale) or
    IsNan(Transform.VerticalScale) or IsInfinite(Transform.VerticalScale) or
    IsNan(Transform.AngleDegrees) or IsInfinite(Transform.AngleDegrees) then
    raise EArgumentException.Create('画像変形の値が不正です。');
  Working := TBitmap.Create;
  try
    // pf24bitへ変更したTBitmapに以前のAlphaFormatが残ることがある。
    // 元の形式が32bit以外ならRGB画像として不透明に扱う。
    Opaque := (Source.PixelFormat <> pf32bit) or (Source.AlphaFormat = afIgnored);
    Working.Assign(Source); Working.PixelFormat := pf32bit;
    W := Working.Width; H := Working.Height;
    SetLength(SourceRows,H);
    for Y := 0 to H-1 do SourceRows[Y] := Working.ScanLine[Y];
    // 別TBitmapでもAssignで元画像とDIBを共有している場合がある。出力を独立させる。
    Dest.SetSize(0,0); Dest.PixelFormat := pf32bit;
    Dest.SetSize(W,H); Dest.AlphaFormat := afPremultiplied;
    if (W = 0) or (H = 0) then Exit;
    CX := (W-1)/2.0; CY := (H-1)/2.0; Bottom := H-1;
    CosA := Cos(DegToRad(Transform.AngleDegrees)); SinA := Sin(DegToRad(Transform.AngleDegrees));
    InverseScale := 1.0/Transform.Scale;
    if Transform.AngleDegrees=0 then begin RenderUnrotated; Exit; end;
    for Y := 0 to H-1 do begin
      Row := Dest.ScanLine[Y]; FillChar(Row^,NativeUInt(W)*SizeOf(TPixelBGRA),0);
      for X := 0 to W-1 do begin
        DX := X-CX-Transform.OffsetX; DY := Y-CY-Transform.OffsetY;
        PX := (CosA*DX+SinA*DY)*InverseScale;
        PY := CY+(-SinA*DX+CosA*DY)*InverseScale;
        if H > 1 then begin
          PY := Bottom+(PY-Bottom)/Transform.VerticalScale;
          HeightRatio := EnsureRange((H-1-PY)/(H-1),0.0,1.0);
          PX := CX+PX-Transform.TopOffsetX*PendulumWeight(HeightRatio,
            Transform.WaistRatio,Transform.JointFlexibility);
        end else PX := CX+PX;
        SX := Round(PX); SY := Round(PY);
        if (SX >= 0) and (SX < W) and (SY >= 0) and (SY < H) then begin
          Row[X] := SourceRows[SY]^[SX];
          if Opaque then Row[X].A := 255;
        end;
      end;
    end;
  finally Working.Free; end;
end;

end.
