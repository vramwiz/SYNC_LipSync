unit SYNC_MusicStudio_BeatData;

// 演奏編集の正本は四分音符を1とした拍。秒はテンポ表から導出する。
// 変換境界の累積秒は読込・変更時に計算し、参照時にJSONやファイルを読まない。
// 小節アンカーを拍子表で四分拍へ変換する。音声・MIDI解析・楽器の姿勢規則は担当しない。
interface

uses System.JSON, System.Generics.Collections, SYNC_MusicStudio_MeterMap;
const
  MUSICSTUDIO_MAX_MEDIA_SECONDS = 604800.0;
  // Evaluation covers legal second-based media at max BPM, plus a navigation margin.
  // Stored tempo points and beat clips still keep their one-million-beat limit.
  MUSICSTUDIO_MAX_QUERY_BEATS = MUSICSTUDIO_MAX_MEDIA_SECONDS*999.99/60+1024;
  MUSICSTUDIO_MAX_QUERY_SECONDS = MUSICSTUDIO_MAX_QUERY_BEATS*60;

type
  TMusicStudioTempoPoint = record
    Beat, BPM, StartSeconds: Double;
  end;

  TMusicStudioTempoMap = class
  private
    FOriginal: TJSONObject;
    FPoints: TArray<TMusicStudioTempoPoint>;
    FPointExtras: TObjectList<TJSONObject>;
    FNumerator, FDenominator: Integer;
    FMeters: TMusicStudioMeterMap;
    procedure MutateMeterChange(Index, Measure, Numerator, Denominator: Integer; Delete: Boolean);
    procedure RebuildSeconds;
    function PointAtBeat(Beat: Double): Integer;
    function PointAtSeconds(Seconds: Double): Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure LoadJSON(const TimingJSON: string); overload;
    procedure LoadJSON(TimingJSON: TJSONObject); overload;
    function TimingJSON: string;
    function BeatToSeconds(Beat: Double): Double;
    function SecondsToBeat(Seconds: Double): Double;
    function BPMAt(Beat: Double): Double;
    function TempoPointIndexAtBeat(Beat: Double): Integer;
    function MeasureAtBeat(Beat: Double): Integer;
    function MeasureStart(Measure: Integer): Double;
    function MeasureLengthAtBeat(Beat: Double): Double;
    function BeatInMeasure(Beat: Double): Double;
    function DenominatorAtBeat(Beat: Double): Integer;
    // 既存のテンポ点を全て一定テンポへ置き換える明示操作。
    procedure SetConstantBPM(BPM: Double);
    // 同じ拍のテンポ点は更新し、異なる拍は追加する。拍位置は変えない。
    procedure SetBPMAt(Beat, BPM: Double);
    // 行の未知フィールドを保持して編集/並べ替えする。0拍の行は移動・削除不可。
    procedure SetTempoPoint(Index: Integer; Beat, BPM: Double);
    procedure DeleteTempoPoint(Index: Integer);
    procedure SetMeter(Numerator, Denominator: Integer);
    // 途中拍子だけを0始まりで参照する。先頭拍子はSetMeterで扱う。
    function MeterChangeCount: Integer;
    function MeterChange(Index: Integer): TMusicStudioMeterPoint;
    // 小節頭へ追加/移動し、tempoの小節アンカーと未知属性を保持する。
    // 全候補を検証後に反映するため、不正/重複/offset超過では状態を変更しない。
    function AddMeterChange(Measure, Numerator, Denominator: Integer): Integer;
    procedure SetMeterChange(Index, Measure, Numerator, Denominator: Integer);
    procedure DeleteMeterChange(Index: Integer);
    function PointCount: Integer;
    function TempoPoint(Index: Integer): TMusicStudioTempoPoint;
    function BeatsPerMeasure: Double;
    property Numerator: Integer read FNumerator;
    property Denominator: Integer read FDenominator;
  end;

  TMusicStudioPerformanceNote = record
    StartBeat, LengthBeats: Double;
    Pitch, Velocity: Integer;
  end;

  TMusicStudioPerformanceData = class
  private
    FOriginal: TJSONObject;
    FNoteExtras: TObjectList<TJSONObject>;
    FNotes: TArray<TMusicStudioPerformanceNote>;
    FLengthBeats: Double;
    FLowestPitch, FHighestPitch: Integer;
    procedure SetLengthBeats(Value: Double);
    procedure UpdatePitchRange;
    procedure ValidateNote(const Note: TMusicStudioPerformanceNote; PatternLength: Double);
  public
    constructor Create;
    destructor Destroy; override;
    procedure LoadJSON(const ConfigJSON: string); overload;
    procedure LoadJSON(ConfigJSON: TJSONObject); overload;
    function ConfigJSON: string;
    function NoteCount: Integer;
    function NoteAt(Index: Integer): TMusicStudioPerformanceNote;
    function AddNote(const Note: TMusicStudioPerformanceNote): Integer;
    procedure SetNote(Index: Integer; const Note: TMusicStudioPerformanceNote);
    procedure DeleteNote(Index: Integer);
    property LengthBeats: Double read FLengthBeats write SetLengthBeats;
    // 読込・音符編集時に更新した値。描画毎に全音符を走査する必要はない。
    property LowestPitch: Integer read FLowestPitch;
    property HighestPitch: Integer read FHighestPitch;
  end;

// PixelsPerBeatは96DPI論理px。DPI切替だけではスナップ単位を変えない。
// 目盛り間隔12px以上を保つ1拍～1/64拍。秒正本の配置は操作確定時だけ拍から変換する。
function MusicStudioSnapStep(PixelsPerBeat: Double): Double;
// 中点は時間の未来側へ寄せる。負の拍にも同じ規則を適用する。
function MusicStudioSnapBeat(Beat, Step: Double): Double;
// A few representable double steps, not a user grid quantization tolerance.
function MusicStudioComparePositions(A,B: Double): Integer;

implementation

uses System.SysUtils, System.Math;

const
  MAX_BEAT = 1000000.0;
  MAX_TEMPO_POINTS = 1024;
  MAX_PERFORMANCE_NOTES = 8192;
function MusicStudioComparePositions(A,B: Double): Integer;
var E: Double;
begin
  E := 8.8817841970012523E-16*Max(1.0,Max(Abs(A),Abs(B)));
  if Abs(A-B)<=E then Result := 0 else if A<B then Result := -1 else Result := 1;
end;

procedure CheckFiniteRange(Value, Minimum, Maximum: Double; const Name: string);
begin
  if IsNan(Value) or IsInfinite(Value) or (Value < Minimum) or (Value > Maximum) then
    raise EArgumentException.Create(Name + ' の値が範囲外です。');
end;

function NumberAt(Obj: TJSONObject; const Key: string; Default: Double): Double;
var Value: TJSONValue;
begin
  Value := Obj.GetValue(Key);
  if Value = nil then Exit(Default);
  if not (Value is TJSONNumber) then
    raise EArgumentException.Create(Key + ' は数値で指定してください。');
  Result := TJSONNumber(Value).AsDouble;
end;

function IntegerAt(Obj: TJSONObject; const Key: string; Default: Integer;
  Minimum, Maximum: Integer): Integer;
var Value: Double;
begin
  Value := NumberAt(Obj,Key,Default); CheckFiniteRange(Value,Minimum,Maximum,Key);
  if Frac(Value) <> 0 then raise EArgumentException.Create(Key + ' は整数で指定してください。');
  Result := Round(Value);
end;

procedure ReplacePair(Obj: TJSONObject; const Key: string; Value: TJSONValue);
begin Obj.RemovePair(Key).Free; Obj.AddPair(Key,Value); end;

function ParseRoot(const Text: string): TJSONObject;
var Parsed: TJSONValue;
begin
  if Trim(Text) = '' then Exit(TJSONObject.Create);
  Parsed := TJSONObject.ParseJSONValue(Text);
  if not (Parsed is TJSONObject) then begin Parsed.Free;
    raise EArgumentException.Create('拍設定JSONが不正です。'); end;
  Result := TJSONObject(Parsed);
end;

function MusicStudioSnapStep(PixelsPerBeat: Double): Double;
begin
  CheckFiniteRange(PixelsPerBeat,0.001,1000000,'時間軸ズーム'); Result := 1;
  while (Result > 1.0/64.0) and (PixelsPerBeat*Result/2.0 >= 12.0) do Result := Result/2.0;
end;

function MusicStudioSnapBeat(Beat, Step: Double): Double;
var Units: Double;
begin
  CheckFiniteRange(Beat,-MUSICSTUDIO_MAX_QUERY_BEATS,MUSICSTUDIO_MAX_QUERY_BEATS,'拍位置');
  CheckFiniteRange(Step,1.0/1024.0,MAX_BEAT,'スナップ単位');
  Units := Beat/Step;
  Result := Floor(Units+0.5+1.0E-10)*Step;
  if Abs(Result) < 1.0E-12 then Result := 0;
end;

constructor TMusicStudioTempoMap.Create;
begin
  inherited; FOriginal := TJSONObject.Create; FPointExtras := TObjectList<TJSONObject>.Create(True); FMeters := TMusicStudioMeterMap.Create;
  FNumerator := 4; FDenominator := 4;
  SetLength(FPoints,1); FPoints[0].Beat := 0; FPoints[0].BPM := 120;
  FPointExtras.Add(TJSONObject.Create);
end;

destructor TMusicStudioTempoMap.Destroy;
begin FMeters.Free; FPointExtras.Free; FOriginal.Free; inherited; end;

procedure TMusicStudioTempoMap.RebuildSeconds;
var I: Integer;
begin
  FPoints[0].StartSeconds := 0;
  for I := 1 to High(FPoints) do FPoints[I].StartSeconds := FPoints[I-1].StartSeconds+
    (FPoints[I].Beat-FPoints[I-1].Beat)*60.0/FPoints[I-1].BPM;
end;

procedure TMusicStudioTempoMap.LoadJSON(const TimingJSON: string);
var Root, Meter, Obj: TJSONObject; Value: TJSONValue; ArrayValue: TJSONArray;
  Candidate: TMusicStudioTempoMap; I,J: Integer; Point: TMusicStudioTempoPoint;
begin
  Root := ParseRoot(TimingJSON); Candidate := TMusicStudioTempoMap.Create;
  try
    if NumberAt(Root,'version',1) <> 1 then
      raise EArgumentException.Create('未対応の拍設定バージョンです。');
    Value := Root.GetValue('meter');
    if Value <> nil then begin
      if not (Value is TJSONObject) then raise EArgumentException.Create('meter はオブジェクトで指定してください。');
      Meter := TJSONObject(Value);
      Candidate.FNumerator := IntegerAt(Meter,'numerator',4,1,32);
      Candidate.FDenominator := IntegerAt(Meter,'denominator',4,1,64);
      if not (Candidate.FDenominator in [1,2,4,8,16,32,64]) then
        raise EArgumentException.Create('拍子の分母は1,2,4,8,16,32,64で指定してください。');
    end;
    Candidate.FMeters.Load(Root,Candidate.FNumerator,Candidate.FDenominator);
    Value := Root.GetValue('tempoPoints');
    if Value <> nil then begin
      if not (Value is TJSONArray) then raise EArgumentException.Create('tempoPoints は配列で指定してください。');
      ArrayValue := TJSONArray(Value);
      if (ArrayValue.Count = 0) or (ArrayValue.Count > MAX_TEMPO_POINTS) then
        raise EArgumentException.Create('テンポ点の数は1～1024で指定してください。');
      Candidate.FPointExtras.Clear; SetLength(Candidate.FPoints,ArrayValue.Count);
      for I := 0 to ArrayValue.Count-1 do begin
        if not (ArrayValue.Items[I] is TJSONObject) then
          raise EArgumentException.Create('テンポ点はオブジェクトで指定してください。');
        Obj := TJSONObject(ArrayValue.Items[I]);
        if Obj.GetValue('measure')<>nil then
          Point.Beat := Candidate.FMeters.BeatAtMeasure(IntegerAt(Obj,'measure',0,1,16000001),NumberAt(Obj,'beatInMeasure',0))
        else Point.Beat := NumberAt(Obj,'beat',-1);
        Point.BPM := NumberAt(Obj,'bpm',-1);
        CheckFiniteRange(Point.Beat,0,MAX_BEAT,'テンポ点の拍');
        CheckFiniteRange(Point.BPM,1,999.99,'BPM'); Point.StartSeconds := 0;
        Candidate.FPoints[I] := Point; Candidate.FPointExtras.Add(TJSONObject(Obj.Clone));
      end;
      // 解析時だけ並べる。未知のテンポ点属性も同じ順に移す。
      for I := 1 to High(Candidate.FPoints) do begin
        J := I;
        while (J > 0) and (Candidate.FPoints[J].Beat < Candidate.FPoints[J-1].Beat) do begin
          Point := Candidate.FPoints[J]; Candidate.FPoints[J] := Candidate.FPoints[J-1];
          Candidate.FPoints[J-1] := Point; Candidate.FPointExtras.Exchange(J,J-1); Dec(J);
        end;
      end;
      if Candidate.FPoints[0].Beat <> 0 then
        raise EArgumentException.Create('先頭のテンポ点は0拍で指定してください。');
      for I := 1 to High(Candidate.FPoints) do
        if Candidate.FPoints[I].Beat = Candidate.FPoints[I-1].Beat then
          raise EArgumentException.Create('同じ拍に複数のテンポ点は指定できません。');
    end;
    Candidate.RebuildSeconds;
    FOriginal.Free; FOriginal := TJSONObject(Root.Clone);
    FPoints := Candidate.FPoints; FNumerator := Candidate.FNumerator; FDenominator := Candidate.FDenominator;
    FPointExtras.Free; FPointExtras := Candidate.FPointExtras; Candidate.FPointExtras := nil;
    FMeters.Free; FMeters := Candidate.FMeters; Candidate.FMeters := nil;
  finally Candidate.Free; Root.Free; end;
end;

procedure TMusicStudioTempoMap.LoadJSON(TimingJSON: TJSONObject);
begin if TimingJSON = nil then LoadJSON('') else LoadJSON(TimingJSON.ToJSON); end;

function TMusicStudioTempoMap.TimingJSON: string;
var Root, Meter, Point: TJSONObject; Points: TJSONArray; Value: TJSONValue; I: Integer;
begin
  Root := TJSONObject(FOriginal.Clone);
  try
    Value := Root.GetValue('meter');
    if Value is TJSONObject then Meter := TJSONObject(Value)
    else begin Meter := TJSONObject.Create; ReplacePair(Root,'meter',Meter); end;
    ReplacePair(Meter,'numerator',TJSONNumber.Create(FNumerator));
    ReplacePair(Meter,'denominator',TJSONNumber.Create(FDenominator));
    ReplacePair(Root,'version',TJSONNumber.Create(1));
    FMeters.WriteChanges(Root);
    Points := TJSONArray.Create; ReplacePair(Root,'tempoPoints',Points);
    for I := 0 to High(FPoints) do begin
      Point := TJSONObject(FPointExtras[I].Clone);
      ReplacePair(Point,'beat',TJSONNumber.Create(FPoints[I].Beat));
      ReplacePair(Point,'measure',TJSONNumber.Create(FMeters.MeasureAtBeat(FPoints[I].Beat)));
      ReplacePair(Point,'beatInMeasure',TJSONNumber.Create(FMeters.BeatInMeasure(FPoints[I].Beat)));
      ReplacePair(Point,'bpm',TJSONNumber.Create(FPoints[I].BPM)); Points.AddElement(Point);
    end;
    Result := Root.ToJSON;
  finally Root.Free; end;
end;

function TMusicStudioTempoMap.PointAtBeat(Beat: Double): Integer;
var L,R,M: Integer;
begin
  CheckFiniteRange(Beat,-MUSICSTUDIO_MAX_QUERY_BEATS,MUSICSTUDIO_MAX_QUERY_BEATS,'拍位置');
  L := 0; R := High(FPoints);
  while L < R do begin M := (L+R+1) div 2;
    if MusicStudioComparePositions(FPoints[M].Beat,Beat)<=0 then L := M else R := M-1; end;
  Result := L;
end;

function TMusicStudioTempoMap.PointAtSeconds(Seconds: Double): Integer;
var L,R,M: Integer;
begin
  CheckFiniteRange(Seconds,-MUSICSTUDIO_MAX_QUERY_SECONDS,MUSICSTUDIO_MAX_QUERY_SECONDS,'秒位置');
  L := 0; R := High(FPoints);
  while L < R do begin M := (L+R+1) div 2;
    if MusicStudioComparePositions(FPoints[M].StartSeconds,Seconds)<=0 then L := M else R := M-1; end;
  Result := L;
end;

function TMusicStudioTempoMap.BeatToSeconds(Beat: Double): Double;
var I: Integer;
begin I := PointAtBeat(Beat); Result := FPoints[I].StartSeconds+(Beat-FPoints[I].Beat)*60/FPoints[I].BPM; end;

function TMusicStudioTempoMap.SecondsToBeat(Seconds: Double): Double;
var I: Integer;
begin I := PointAtSeconds(Seconds); Result := FPoints[I].Beat+(Seconds-FPoints[I].StartSeconds)*FPoints[I].BPM/60; end;

function TMusicStudioTempoMap.BPMAt(Beat: Double): Double;
begin Result := FPoints[PointAtBeat(Beat)].BPM; end;
function TMusicStudioTempoMap.TempoPointIndexAtBeat(Beat: Double): Integer;
begin Result := PointAtBeat(Beat); end;
function TMusicStudioTempoMap.MeasureAtBeat(Beat: Double): Integer;
begin Result := FMeters.MeasureAtBeat(Beat); end;
function TMusicStudioTempoMap.MeasureStart(Measure: Integer): Double;
begin Result := FMeters.MeasureStart(Measure); end;
function TMusicStudioTempoMap.MeasureLengthAtBeat(Beat: Double): Double;
begin Result := FMeters.MeasureLengthAtBeat(Beat); end;
function TMusicStudioTempoMap.BeatInMeasure(Beat: Double): Double;
begin Result := FMeters.BeatInMeasure(Beat); end;
function TMusicStudioTempoMap.DenominatorAtBeat(Beat: Double): Integer;
begin Result := FMeters.DenominatorAtBeat(Beat); end;

procedure TMusicStudioTempoMap.SetConstantBPM(BPM: Double);
begin
  CheckFiniteRange(BPM,1,999.99,'BPM');
  SetLength(FPoints,1); FPoints[0].Beat := 0; FPoints[0].BPM := BPM; FPoints[0].StartSeconds := 0;
  FPointExtras.Clear; FPointExtras.Add(TJSONObject.Create);
end;

procedure TMusicStudioTempoMap.SetBPMAt(Beat, BPM: Double);
var I,J: Integer;
begin
  CheckFiniteRange(Beat,0,MAX_BEAT,'テンポ点の拍'); CheckFiniteRange(BPM,1,999.99,'BPM');
  I := 0; while (I < Length(FPoints)) and (FPoints[I].Beat < Beat) do Inc(I);
  if (I < Length(FPoints)) and (FPoints[I].Beat = Beat) then FPoints[I].BPM := BPM
  else begin
    if Length(FPoints) >= MAX_TEMPO_POINTS then raise EArgumentException.Create('テンポ点の上限1024を超えます。');
    SetLength(FPoints,Length(FPoints)+1);
    for J := High(FPoints) downto I+1 do FPoints[J] := FPoints[J-1];
    FPoints[I].Beat := Beat; FPoints[I].BPM := BPM; FPointExtras.Insert(I,TJSONObject.Create);
  end;
  RebuildSeconds;
end;

function TMusicStudioTempoMap.MeterChangeCount: Integer;
begin Result := FMeters.PointCount-1; end;
function TMusicStudioTempoMap.MeterChange(Index: Integer): TMusicStudioMeterPoint;
begin
  if (Index<0) or (Index>=MeterChangeCount) then raise EArgumentOutOfRangeException.Create('途中拍子の行が範囲外です。');
  Result := FMeters.PointAt(Index+1);
end;

procedure TMusicStudioTempoMap.MutateMeterChange(Index, Measure, Numerator, Denominator: Integer; Delete: Boolean);
var Root, Entry, Existing: TJSONObject; Changes, Old: TJSONArray; I: Integer; Added: Boolean;
begin
  if (Index < -1) or (Index>=MeterChangeCount) or (Delete and (Index<0)) then
    raise EArgumentOutOfRangeException.Create('途中拍子の行が範囲外です。');
  if not Delete then begin
    if (Measure<2) or (Measure>16000001) then raise EArgumentException.Create('途中拍子の開始小節は2以上で入力してください。');
    if (Numerator<1) or (Numerator>32) or not (Denominator in [1,2,4,8,16,32,64]) then
      raise EArgumentException.Create('拍子の分子は1～32、分母は1/2/4/8/16/32/64です。');
    for I := 0 to MeterChangeCount-1 do
      if (I<>Index) and (MeterChange(I).Measure=Measure) then
        raise EArgumentException.Create('同じ小節の拍子変更があります。');
  end;
  Root := TJSONObject.ParseJSONValue(TimingJSON) as TJSONObject;
  Entry := nil; Changes := nil;
  try
    Old := nil;
    if Root.GetValue('meterChanges') is TJSONArray then Old := TJSONArray(Root.GetValue('meterChanges'));
    if not Delete then begin
      if Index>=0 then Entry := TJSONObject(Old.Items[Index].Clone) else Entry := TJSONObject.Create;
      ReplacePair(Entry,'measure',TJSONNumber.Create(Measure));
      ReplacePair(Entry,'numerator',TJSONNumber.Create(Numerator));
      ReplacePair(Entry,'denominator',TJSONNumber.Create(Denominator));
      Entry.RemovePair('beat').Free;
    end;
    Changes := TJSONArray.Create; Added := Delete;
    for I := 0 to MeterChangeCount-1 do begin
      if I=Index then Continue;
      Existing := TJSONObject(Old.Items[I]);
      if not Added and (MeterChange(I).Measure>Measure) then begin
        Changes.AddElement(Entry); Entry := nil; Added := True;
      end;
      Changes.AddElement(TJSONObject(Existing.Clone));
    end;
    if not Added then begin Changes.AddElement(Entry); Entry := nil; end;
    ReplacePair(Root,'meterChanges',Changes); Changes := nil;
    // LoadJSONは候補mapでtempoの小節内offsetも検証し、成功時だけ全状態を交換する。
    LoadJSON(Root);
  finally Changes.Free; Entry.Free; Root.Free; end;
end;

function TMusicStudioTempoMap.AddMeterChange(Measure, Numerator, Denominator: Integer): Integer;
begin
  MutateMeterChange(-1,Measure,Numerator,Denominator,False);
  Result := 0; while MeterChange(Result).Measure<>Measure do Inc(Result);
end;
procedure TMusicStudioTempoMap.SetMeterChange(Index, Measure, Numerator, Denominator: Integer);
begin MeterChange(Index); MutateMeterChange(Index,Measure,Numerator,Denominator,False); end;
procedure TMusicStudioTempoMap.DeleteMeterChange(Index: Integer);
begin MutateMeterChange(Index,0,0,0,True); end;

function TMusicStudioTempoMap.PointCount: Integer;
begin Result := Length(FPoints); end;

procedure TMusicStudioTempoMap.SetTempoPoint(Index: Integer; Beat, BPM: Double);
var I,J: Integer; Point: TMusicStudioTempoPoint;
begin
  TempoPoint(Index);
  CheckFiniteRange(Beat,0,MAX_BEAT,'テンポ点の拍'); CheckFiniteRange(BPM,1,999.99,'BPM');
  if (Index = 0) and (Beat <> 0) then raise EArgumentException.Create('先頭のテンポ点は0拍で固定です。');
  for I := 0 to High(FPoints) do
    if (I <> Index) and (FPoints[I].Beat = Beat) then
      raise EArgumentException.Create('同じ拍に複数のテンポ点は指定できません。');
  FPoints[Index].Beat := Beat; FPoints[Index].BPM := BPM;
  J := Index;
  while (J > 0) and (FPoints[J].Beat < FPoints[J-1].Beat) do begin
    Point := FPoints[J]; FPoints[J] := FPoints[J-1]; FPoints[J-1] := Point;
    FPointExtras.Exchange(J,J-1); Dec(J);
  end;
  while (J < High(FPoints)) and (FPoints[J].Beat > FPoints[J+1].Beat) do begin
    Point := FPoints[J]; FPoints[J] := FPoints[J+1]; FPoints[J+1] := Point;
    FPointExtras.Exchange(J,J+1); Inc(J);
  end;
  RebuildSeconds;
end;

procedure TMusicStudioTempoMap.DeleteTempoPoint(Index: Integer);
var I: Integer;
begin
  TempoPoint(Index);
  if Index = 0 then raise EArgumentException.Create('0拍のテンポ点は削除できません。');
  for I := Index to High(FPoints)-1 do FPoints[I] := FPoints[I+1];
  SetLength(FPoints,Length(FPoints)-1); FPointExtras.Delete(Index); RebuildSeconds;
end;

procedure TMusicStudioTempoMap.SetMeter(Numerator, Denominator: Integer);
var Root,Meter: TJSONObject;
begin
  if (Numerator < 1) or (Numerator > 32) then
    raise EArgumentException.Create('拍子の分子は1～32で指定してください。');
  if not (Denominator in [1,2,4,8,16,32,64]) then
    raise EArgumentException.Create('拍子の分母は1,2,4,8,16,32,64で指定してください。');
  Root := TJSONObject.ParseJSONValue(TimingJSON) as TJSONObject;
  try Meter := Root.GetValue('meter') as TJSONObject;
    ReplacePair(Meter,'numerator',TJSONNumber.Create(Numerator)); ReplacePair(Meter,'denominator',TJSONNumber.Create(Denominator));
    LoadJSON(Root);
  finally Root.Free; end;
end;

function TMusicStudioTempoMap.TempoPoint(Index: Integer): TMusicStudioTempoPoint;
begin
  if (Index < 0) or (Index >= Length(FPoints)) then raise EArgumentOutOfRangeException.Create('テンポ点番号');
  Result := FPoints[Index];
end;

function TMusicStudioTempoMap.BeatsPerMeasure: Double;
begin Result := FNumerator*4.0/FDenominator; end;

constructor TMusicStudioPerformanceData.Create;
begin
  inherited; FOriginal := TJSONObject.Create; FNoteExtras := TObjectList<TJSONObject>.Create(True);
  FLengthBeats := 16; FLowestPitch := -1; FHighestPitch := -1;
end;

destructor TMusicStudioPerformanceData.Destroy;
begin FOriginal.Free; FNoteExtras.Free; inherited; end;

procedure TMusicStudioPerformanceData.ValidateNote(const Note: TMusicStudioPerformanceNote; PatternLength: Double);
begin
  CheckFiniteRange(Note.StartBeat,0,MAX_BEAT,'音符の開始拍');
  CheckFiniteRange(Note.LengthBeats,1.0/1024.0,MAX_BEAT,'音符の長さ');
  if Note.StartBeat+Note.LengthBeats > PatternLength+1.0E-9 then
    raise EArgumentException.Create('音符がパターンの長さを超えています。');
  if (Note.Pitch < 0) or (Note.Pitch > 127) then raise EArgumentException.Create('音高は0～127で指定してください。');
  if (Note.Velocity < 1) or (Note.Velocity > 127) then raise EArgumentException.Create('強さは1～127で指定してください。');
end;

procedure TMusicStudioPerformanceData.UpdatePitchRange;
var Note: TMusicStudioPerformanceNote;
begin
  FLowestPitch := -1; FHighestPitch := -1;
  for Note in FNotes do begin
    if (FLowestPitch = -1) or (Note.Pitch < FLowestPitch) then FLowestPitch := Note.Pitch;
    if Note.Pitch > FHighestPitch then FHighestPitch := Note.Pitch;
  end;
end;

procedure TMusicStudioPerformanceData.SetLengthBeats(Value: Double);
var Note: TMusicStudioPerformanceNote;
begin
  CheckFiniteRange(Value,1.0/64.0,MAX_BEAT,'パターンの長さ');
  for Note in FNotes do ValidateNote(Note,Value);
  FLengthBeats := Value;
end;

procedure TMusicStudioPerformanceData.LoadJSON(const ConfigJSON: string);
var Root, Obj: TJSONObject; Value: TJSONValue; Notes: TJSONArray;
  Candidate: TMusicStudioPerformanceData; I: Integer; Note: TMusicStudioPerformanceNote;
begin
  Root := ParseRoot(ConfigJSON); Candidate := TMusicStudioPerformanceData.Create;
  try
    if NumberAt(Root,'version',1) <> 1 then raise EArgumentException.Create('未対応の演奏設定バージョンです。');
    Candidate.LengthBeats := NumberAt(Root,'lengthBeats',16);
    Value := Root.GetValue('notes');
    if Value <> nil then begin
      if not (Value is TJSONArray) then raise EArgumentException.Create('notes は配列で指定してください。');
      Notes := TJSONArray(Value);
      if Notes.Count > MAX_PERFORMANCE_NOTES then raise EArgumentException.Create('音符数の上限8192を超えます。');
      SetLength(Candidate.FNotes,Notes.Count);
      for I := 0 to Notes.Count-1 do begin
        if not (Notes.Items[I] is TJSONObject) then raise EArgumentException.Create('音符はオブジェクトで指定してください。');
        Obj := TJSONObject(Notes.Items[I]); Note.StartBeat := NumberAt(Obj,'startBeat',-1);
        Note.LengthBeats := NumberAt(Obj,'lengthBeats',-1);
        Note.Pitch := IntegerAt(Obj,'pitch',60,0,127); Note.Velocity := IntegerAt(Obj,'velocity',100,1,127);
        Candidate.ValidateNote(Note,Candidate.LengthBeats); Candidate.FNotes[I] := Note;
        Candidate.FNoteExtras.Add(TJSONObject(Obj.Clone));
      end;
    end;
    Candidate.UpdatePitchRange;
    FOriginal.Free; FOriginal := TJSONObject(Root.Clone); FNotes := Candidate.FNotes;
    FLengthBeats := Candidate.FLengthBeats; FLowestPitch := Candidate.FLowestPitch; FHighestPitch := Candidate.FHighestPitch;
    FNoteExtras.Free; FNoteExtras := Candidate.FNoteExtras; Candidate.FNoteExtras := nil;
  finally Candidate.Free; Root.Free; end;
end;

procedure TMusicStudioPerformanceData.LoadJSON(ConfigJSON: TJSONObject);
begin if ConfigJSON = nil then LoadJSON('') else LoadJSON(ConfigJSON.ToJSON); end;

function TMusicStudioPerformanceData.ConfigJSON: string;
var Root, Obj: TJSONObject; Notes: TJSONArray; I: Integer;
begin
  Root := TJSONObject(FOriginal.Clone);
  try
    ReplacePair(Root,'version',TJSONNumber.Create(1));
    ReplacePair(Root,'lengthBeats',TJSONNumber.Create(FLengthBeats));
    Notes := TJSONArray.Create; ReplacePair(Root,'notes',Notes);
    for I := 0 to High(FNotes) do begin
      Obj := TJSONObject(FNoteExtras[I].Clone);
      ReplacePair(Obj,'startBeat',TJSONNumber.Create(FNotes[I].StartBeat));
      ReplacePair(Obj,'lengthBeats',TJSONNumber.Create(FNotes[I].LengthBeats));
      ReplacePair(Obj,'pitch',TJSONNumber.Create(FNotes[I].Pitch));
      ReplacePair(Obj,'velocity',TJSONNumber.Create(FNotes[I].Velocity)); Notes.AddElement(Obj);
    end;
    Result := Root.ToJSON;
  finally Root.Free; end;
end;

function TMusicStudioPerformanceData.NoteCount: Integer;
begin Result := Length(FNotes); end;

function TMusicStudioPerformanceData.NoteAt(Index: Integer): TMusicStudioPerformanceNote;
begin
  if (Index < 0) or (Index >= Length(FNotes)) then raise EArgumentOutOfRangeException.Create('音符番号');
  Result := FNotes[Index];
end;

function TMusicStudioPerformanceData.AddNote(const Note: TMusicStudioPerformanceNote): Integer;
begin
  ValidateNote(Note,FLengthBeats);
  if Length(FNotes) >= MAX_PERFORMANCE_NOTES then raise EArgumentException.Create('音符数の上限8192を超えます。');
  Result := Length(FNotes); SetLength(FNotes,Result+1); FNotes[Result] := Note;
  FNoteExtras.Add(TJSONObject.Create); UpdatePitchRange;
end;

procedure TMusicStudioPerformanceData.SetNote(Index: Integer; const Note: TMusicStudioPerformanceNote);
begin
  if (Index < 0) or (Index >= Length(FNotes)) then raise EArgumentOutOfRangeException.Create('音符番号');
  ValidateNote(Note,FLengthBeats); FNotes[Index] := Note; UpdatePitchRange;
end;

procedure TMusicStudioPerformanceData.DeleteNote(Index: Integer);
var I: Integer;
begin
  if (Index < 0) or (Index >= Length(FNotes)) then raise EArgumentOutOfRangeException.Create('音符番号');
  for I := Index to High(FNotes)-1 do FNotes[I] := FNotes[I+1];
  SetLength(FNotes,Length(FNotes)-1); FNoteExtras.Delete(Index); UpdatePitchRange;
end;

end.
