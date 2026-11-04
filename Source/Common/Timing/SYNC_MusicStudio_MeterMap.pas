unit SYNC_MusicStudio_MeterMap;

// Meter changes are anchored to one-based measures. Quarter beats are derived,
// independent of BPM; old beat-only changes are accepted on a measure boundary.
interface
uses System.JSON;
type
  TMusicStudioMeterPoint = record
    Beat: Double;
    Measure, Numerator, Denominator: Integer;
  end;
  TMusicStudioMeterMap = class
  private
    FPoints: TArray<TMusicStudioMeterPoint>;
    function PointAtBeat(Beat: Double): Integer;
    function PointAtMeasure(Measure: Integer): Integer;
  public
    constructor Create;
    procedure Load(Root: TJSONObject; Numerator,Denominator: Integer);
    procedure WriteChanges(Root: TJSONObject);
    // 先頭拍子を含むsnapshotを値で返す。範囲外indexは例外とし、配列の所有権は移さない。
    function PointCount: Integer;
    function PointAt(Index: Integer): TMusicStudioMeterPoint;
    function MeasureAtBeat(Beat: Double): Integer;
    function MeasureStart(Measure: Integer): Double;
    function MeasureLengthAtBeat(Beat: Double): Double;
    function BeatInMeasure(Beat: Double): Double;
    function BeatAtMeasure(Measure: Integer; Offset: Double): Double;
    function DenominatorAtBeat(Beat: Double): Integer;
  end;
implementation
uses System.SysUtils, System.Math, System.Generics.Collections;
procedure Put(O: TJSONObject; const K: string; V: TJSONValue);
begin O.RemovePair(K).Free; O.AddPair(K,V); end;
function IntegerField(O: TJSONObject; const K: string; Default,Min,Max: Integer): Integer;
var V: TJSONValue;
begin V := O.GetValue(K); if V=nil then Exit(Default);
  if not (V is TJSONNumber) or not TryStrToInt(V.Value,Result) or (Result<Min) or (Result>Max) then
    raise EArgumentException.Create('meterChanges.'+K+' is out of range');
end;
constructor TMusicStudioMeterMap.Create;
begin inherited; Load(nil,4,4); end;
procedure TMusicStudioMeterMap.Load(Root: TJSONObject; Numerator,Denominator: Integer);
var A: TJSONValue; I: Integer; O: TJSONObject; Prev,P: TMusicStudioMeterPoint; B,Delta: Double;
begin
  SetLength(FPoints,1); FPoints[0].Beat := 0; FPoints[0].Measure := 1;
  FPoints[0].Numerator := Numerator; FPoints[0].Denominator := Denominator;
  if Root=nil then Exit; A := Root.GetValue('meterChanges'); if (A=nil) or (A is TJSONNull) then Exit;
  if not (A is TJSONArray) or (TJSONArray(A).Count>1024) then raise EArgumentException.Create('meterChanges must be an array of at most 1024 changes');
  for I := 0 to TJSONArray(A).Count-1 do begin
    if not (TJSONArray(A).Items[I] is TJSONObject) then raise EArgumentException.Create('meterChanges entry must be an object');
    O := TJSONObject(TJSONArray(A).Items[I]); Prev := FPoints[High(FPoints)];
    P.Numerator := IntegerField(O,'numerator',0,1,32); P.Denominator := IntegerField(O,'denominator',0,1,64);
    if (P.Numerator=0) or not (P.Denominator in [1,2,4,8,16,32,64]) then raise EArgumentException.Create('Unsupported meter');
    if O.GetValue('measure')<>nil then P.Measure := IntegerField(O,'measure',0,2,16000001)
    else begin
      if not (O.GetValue('beat') is TJSONNumber) then raise EArgumentException.Create('Meter change needs measure or beat');
      B := TJSONNumber(O.GetValue('beat')).AsDouble;
      if IsNan(B) or IsInfinite(B) or (B<=Prev.Beat) or (B>1000000) then raise EArgumentException.Create('Meter change beat is out of range');
      Delta := (B-Prev.Beat)/(Prev.Numerator*4.0/Prev.Denominator);
      if Abs(Delta-Round(Delta))>1E-8 then raise EArgumentException.Create('Meter changes must start at a measure boundary');
      P.Measure := Prev.Measure+Round(Delta);
    end;
    if P.Measure<=Prev.Measure then raise EArgumentException.Create('Meter changes must be in increasing measure order');
    P.Beat := Prev.Beat+(P.Measure-Prev.Measure)*(Prev.Numerator*4.0/Prev.Denominator);
    if P.Beat>1000000 then raise EArgumentException.Create('Meter change exceeds 1000000 quarter beats');
    SetLength(FPoints,Length(FPoints)+1); FPoints[High(FPoints)] := P;
  end;
end;
procedure TMusicStudioMeterMap.WriteChanges(Root: TJSONObject);
var A,Old: TJSONArray; I: Integer; O: TJSONObject; P: TMusicStudioMeterPoint;
begin
  if Length(FPoints)=1 then Exit; Old := Root.GetValue('meterChanges') as TJSONArray; A := TJSONArray.Create;
  for I := 1 to High(FPoints) do begin
    if (Old<>nil) and (I-1<Old.Count) then O := TJSONObject(Old.Items[I-1].Clone) else O := TJSONObject.Create;
    P := FPoints[I]; Put(O,'measure',TJSONNumber.Create(P.Measure)); Put(O,'beat',TJSONNumber.Create(P.Beat));
    Put(O,'numerator',TJSONNumber.Create(P.Numerator)); Put(O,'denominator',TJSONNumber.Create(P.Denominator)); A.AddElement(O);
  end;
  Put(Root,'meterChanges',A);
end;
function TMusicStudioMeterMap.PointCount: Integer;
begin Result := Length(FPoints); end;
function TMusicStudioMeterMap.PointAt(Index: Integer): TMusicStudioMeterPoint;
begin
  if (Index<0) or (Index>=Length(FPoints)) then raise EArgumentOutOfRangeException.Create('Meter index');
  Result := FPoints[Index];
end;
function TMusicStudioMeterMap.PointAtBeat(Beat: Double): Integer;
begin Result := High(FPoints); while (Result>0) and (Beat<FPoints[Result].Beat) do Dec(Result); end;
function TMusicStudioMeterMap.PointAtMeasure(Measure: Integer): Integer;
begin Result := High(FPoints); while (Result>0) and (Measure<FPoints[Result].Measure) do Dec(Result); end;
function TMusicStudioMeterMap.MeasureAtBeat(Beat: Double): Integer;
var P: TMusicStudioMeterPoint;
begin P := FPoints[PointAtBeat(Beat)]; Result := P.Measure+Floor(Max(0.0,Beat-P.Beat)/(P.Numerator*4.0/P.Denominator)+1E-9); end;
function TMusicStudioMeterMap.MeasureStart(Measure: Integer): Double;
var P: TMusicStudioMeterPoint;
begin P := FPoints[PointAtMeasure(Measure)]; Result := P.Beat+(Measure-P.Measure)*(P.Numerator*4.0/P.Denominator); end;
function TMusicStudioMeterMap.MeasureLengthAtBeat(Beat: Double): Double;
var P: TMusicStudioMeterPoint;
begin P := FPoints[PointAtBeat(Beat)]; Result := P.Numerator*4.0/P.Denominator; end;
function TMusicStudioMeterMap.BeatInMeasure(Beat: Double): Double;
begin Result := Max(0.0,Beat-MeasureStart(MeasureAtBeat(Beat))); end;
function TMusicStudioMeterMap.BeatAtMeasure(Measure: Integer; Offset: Double): Double;
begin
  if (Measure<1) or IsNan(Offset) or IsInfinite(Offset) or (Offset<0) or
    (Offset>=MeasureLengthAtBeat(MeasureStart(Measure))) then raise EArgumentException.Create('Tempo measure/offset is out of range');
  Result := MeasureStart(Measure)+Offset;
end;
function TMusicStudioMeterMap.DenominatorAtBeat(Beat: Double): Integer;
begin Result := FPoints[PointAtBeat(Beat)].Denominator; end;
end.
