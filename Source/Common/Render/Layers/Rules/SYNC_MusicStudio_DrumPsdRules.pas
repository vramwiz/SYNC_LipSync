unit SYNC_MusicStudio_DrumPsdRules;

// DRUM_PSD_NAMING.mdの読込時解析。画像/作品/共有設定を書かず、不変の固定キー参照を生成する。
// 解決時は辞書だけを読む。複製は解析済みテーブルをコピーし、描画のたびに名称を解析しない。
interface
uses System.SysUtils, System.Generics.Collections;
const
  // 未確定項目はユーザー許可に基づく仮名。正式化時にここへ集約して変更する。
  DRUM_PSD_BASE_NAME = 'BASE';
  DRUM_PSD_COMMON_ID = 'CM';
  DRUM_PSD_EFFECT_GROUP = 'FX';
  DRUM_PSD_STICK_ID = 'ST';
  DRUM_PSD_CRASH_ID = 'CR';
  DRUM_PSD_RIDE_ID = 'RD';
type
  TDrumPsdLayer = record
    Key, ParentKey, Name, Path: string;
    IsGroup, Visible: Boolean;
    SourceIndex: Integer;
  end;
  TDrumPsdReference = record
    Layer: TDrumPsdLayer;
    Identifier, Instrument, RootGroup, Part, Prefix, Suffix, TargetKind: string;
    Stage: Integer;
    Exclusive, AlwaysVisible, Ambiguous, IsBase: Boolean;
  end;
  TDrumPsdResolution = (dprDirect, dprFallback, dprBase, dprAmbiguous);
  TDrumPsdBinding = record
    CommandID, Instrument, RequestedPart, ActualPart, TargetKind: string;
    Stage: Integer;
    State: TDrumPsdResolution;
    ReferenceIndices: TArray<Integer>;
  end;
  TMusicStudioDrumPsdRules = class
  private
    FReferences: TArray<TDrumPsdReference>;
    FDiagnostics: TArray<string>;
    FBindings: TDictionary<string,TDrumPsdBinding>;
    FCommands: TDictionary<string,TDrumPsdBinding>;
    FHasDrumStructure: Boolean;
    FAnalysisCount: Integer;
    function Candidate(const Instrument,Part,TargetKind: string; Stage: Integer): TDrumPsdBinding;
    function CompileBinding(const Instrument,Part,TargetKind: string; Stage: Integer): TDrumPsdBinding;
    procedure CompileBindings;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    // レイヤー情報の値コピーから旧解析を置換する。画像・原PSD・共有設定は変更しない。
    procedure Build(const Layers: TArray<TDrumPsdLayer>);
    // 呼出元所有の独立snapshotを返す。PSD名称の再解析は行わない。
    function Clone: TMusicStudioDrumPsdRules;
    // 戻り値の配列は呼出元専用コピー。変更しても共有snapshotを変更しない。
    function Resolve(const Instrument,Part: string; Stage: Integer; const TargetKind: string = ''): TDrumPsdBinding;
    function ResolveCommand(const CommandID: string; Stage: Integer): TDrumPsdBinding;
    function ReferenceAt(Index: Integer): TDrumPsdReference;
    function ReferenceCount: Integer;
    // 開発用JSON。sourceVisibleはPSD読込時の状態で、演奏中の表示状態とは区別する。
    function DiagnosticJSON: string;
    property HasDrumStructure: Boolean read FHasDrumStructure;
    property AnalysisCount: Integer read FAnalysisCount;
  end;
function ParseDrumPsdLayerName(const Name: string; out Reference: TDrumPsdReference): Boolean;
implementation
uses System.JSON, SYNC_MusicStudio_ArtLayerName;

function ParseDrumPsdLayerName(const Name: string; out Reference: TDrumPsdReference): Boolean;
var Parts: TArtLayerNameParts; Body,Instrument: string; I,L: Integer;
begin
  Reference := Default(TDrumPsdReference); Parts := ParseLayerName(Name);
  Body := Parts.DisplayName; Reference.Prefix := Parts.Prefix; Reference.Suffix := Parts.Suffix;
  // 添付仕様で明示された末尾*だけを追加認識。未知記号や複数の末尾*は削らない。
  if Body.EndsWith('*') then begin
    Delete(Body,Length(Body),1); Reference.Suffix := '*'+Reference.Suffix;
    Reference.Exclusive := True;
  end;
  Reference.Exclusive := Reference.Exclusive or (Pos('*',Parts.Prefix)>0);
  Reference.AlwaysVisible := Pos('!',Parts.Prefix)>0;
  if Body=DRUM_PSD_BASE_NAME then begin
    Reference.Identifier := Body; Reference.Stage := -1; Reference.IsBase := True; Exit(True);
  end;
  if Body.EndsWith('_'+DRUM_PSD_BASE_NAME) then begin
    Instrument := Copy(Body,1,Length(Body)-Length(DRUM_PSD_BASE_NAME)-1);
    if (Length(Instrument)<1) or (Length(Instrument)>3) then Exit(False);
    if not CharInSet(Instrument[1],['A'..'Z']) then Exit(False);
    for I := 1 to Length(Instrument) do if not CharInSet(Instrument[I],['A'..'Z','0'..'9']) then Exit(False);
    Reference.Identifier := Body; Reference.Instrument := Instrument; Reference.Stage := -1; Reference.IsBase := True; Exit(True);
  end;
  L := Length(Body); Result := False;
  if (L<3) or (L>5) or (Body[L-1]<>'_') or not CharInSet(Body[L],['0'..'9']) then Exit;
  if not CharInSet(Body[1],['A'..'Z']) then Exit;
  for I := 1 to L-2 do if not CharInSet(Body[I],['A'..'Z','0'..'9']) then Exit;
  Reference.Identifier := Body; Reference.Instrument := Copy(Body,1,L-2);
  Reference.Stage := Ord(Body[L])-Ord('0'); Result := True;
end;
function BindingKey(const Instrument,Part: string; Stage: Integer): string;
begin Result := Part+'|'+Instrument+'|'+IntToStr(Stage); end;
constructor TMusicStudioDrumPsdRules.Create;
begin
  inherited; FBindings := TDictionary<string,TDrumPsdBinding>.Create;
  FCommands := TDictionary<string,TDrumPsdBinding>.Create;
end;
destructor TMusicStudioDrumPsdRules.Destroy;
begin FCommands.Free; FBindings.Free; inherited; end;
procedure TMusicStudioDrumPsdRules.Clear;
begin FReferences := nil; FDiagnostics := nil; FBindings.Clear; FCommands.Clear; FHasDrumStructure := False; end;
procedure TMusicStudioDrumPsdRules.Build(const Layers: TArray<TDrumPsdLayer>);
var ByKey: TDictionary<string,Integer>; Seen: TDictionary<string,Integer>;
  Refs: TList<TDrumPsdReference>; Issues: TList<string>;
  R,Previous: TDrumPsdReference; I,J,N: Integer; Parent,GroupName,Logical: string;
  Roots: TDictionary<string,Boolean>; Names: TArtLayerNameParts;
begin
  Clear; Inc(FAnalysisCount);
  ByKey := TDictionary<string,Integer>.Create; Seen := TDictionary<string,Integer>.Create;
  Roots := TDictionary<string,Boolean>.Create; Refs := TList<TDrumPsdReference>.Create; Issues := TList<string>.Create;
  try
    for I := 0 to High(Layers) do ByKey.AddOrSetValue(Layers[I].Key,I);
    for I := 0 to High(Layers) do begin
      Names := ParseLayerName(Layers[I].Name);
      if (Layers[I].ParentKey='') and Layers[I].IsGroup and
        ((Names.DisplayName='Back') or (Names.DisplayName='Character') or (Names.DisplayName='Front')) then begin
        if Roots.ContainsKey(Names.DisplayName) then begin
          Issues.Add('ルートグループが重複: '+Names.DisplayName); Roots[Names.DisplayName] := False;
        end else Roots.Add(Names.DisplayName,True);
      end;
    end;
    FHasDrumStructure := Roots.ContainsKey('Back') or Roots.ContainsKey('Character') or Roots.ContainsKey('Front');
    if not FHasDrumStructure then Exit;
    if not Roots.ContainsKey('Back') then Issues.Add('Backグループなし');
    if not Roots.ContainsKey('Character') then Issues.Add('Characterグループなし');
    if not Roots.ContainsKey('Front') then Issues.Add('Frontグループなし');
    for I := 0 to High(Layers) do begin
      if not ParseDrumPsdLayerName(Layers[I].Name,R) then begin
        if Pos('_',Layers[I].Name)>0 then Issues.Add('命名規則に不一致（未登録）: '+Layers[I].Path);
        Continue;
      end;
      R.Layer := Layers[I]; Parent := Layers[I].ParentKey; N := 0;
      R.TargetKind := 'instrument';
      while (Parent<>'') and ByKey.TryGetValue(Parent,J) do begin
        Inc(N); if N>128 then begin Issues.Add('階層循環または上限超過: '+Layers[I].Path); Break; end;
        Names := ParseLayerName(Layers[J].Name); GroupName := Names.DisplayName;
        if Layers[J].IsGroup then begin
          if GroupName=DRUM_PSD_EFFECT_GROUP then R.TargetKind := 'effect';
          if (R.Part='') and ((GroupName='LA') or (GroupName='RA') or (GroupName='LL') or (GroupName='RL')) then R.Part := GroupName;
          if (Layers[J].ParentKey='') and ((GroupName='Back') or (GroupName='Character') or (GroupName='Front')) then R.RootGroup := GroupName;
        end;
        Parent := Layers[J].ParentKey;
      end;
      if N>128 then Continue;
      if (R.RootGroup='Character') and (R.Part='') and (R.TargetKind='effect') then R.Part := 'Character';
      if (R.RootGroup='') or ((R.RootGroup='Character') and (R.Part='')) then begin
        Issues.Add('演奏対象の所属部位を特定できない（未登録）: '+Layers[I].Path); Continue;
      end;
      if R.RootGroup<>'Character' then R.Part := R.RootGroup;
      if (R.RootGroup='Character') and (R.TargetKind<>'effect') then R.TargetKind := 'person';
      R.Ambiguous := not Roots[R.RootGroup];
      Logical := Layers[I].ParentKey+'|'+R.Identifier;
      if Seen.TryGetValue(Logical,J) then begin
        R.Ambiguous := True; Previous := Refs[J]; Previous.Ambiguous := True; Refs[J] := Previous;
        Issues.Add('同じ親階層で識別名が重複（解決対象外）: '+Layers[I].Path);
      end else Seen.Add(Logical,Refs.Count);
      Refs.Add(R);
    end;
    FReferences := Refs.ToArray; FDiagnostics := Issues.ToArray; CompileBindings;
  finally Issues.Free; Refs.Free; Roots.Free; Seen.Free; ByKey.Free; end;
end;
function TMusicStudioDrumPsdRules.Candidate(const Instrument,Part,TargetKind: string; Stage: Integer): TDrumPsdBinding;
var Indices: TList<Integer>; I: Integer; R: TDrumPsdReference;
begin
  Result := Default(TDrumPsdBinding); Result.Instrument := Instrument;
  Result.RequestedPart := Part; Result.ActualPart := Part; Result.TargetKind := TargetKind; Result.Stage := Stage; Result.State := dprBase;
  Indices := TList<Integer>.Create;
  try
    for I := 0 to High(FReferences) do begin
      R := FReferences[I];
      if (R.Instrument=Instrument) and (R.Part=Part) and (R.TargetKind=TargetKind) and (R.Stage=Stage) then begin
        if R.Ambiguous then Result.State := dprAmbiguous else Indices.Add(I);
      end;
    end;
    if Result.State=dprAmbiguous then Exit;
    Result.ReferenceIndices := Indices.ToArray;
    if Indices.Count>0 then Result.State := dprDirect;
  finally Indices.Free; end;
end;
function TMusicStudioDrumPsdRules.CompileBinding(const Instrument,Part,TargetKind: string; Stage: Integer): TDrumPsdBinding;
var Variants: TArray<string>; Target,Variant: string; R: TDrumPsdBinding; Pass: Integer;
begin
  Variants := [Instrument];
  if (TargetKind='person') and ((Part='LA') or (Part='RA')) then begin
    Variants := [Instrument,DRUM_PSD_COMMON_ID];
    if Instrument='HO' then Variants := ['HO','H','HC',DRUM_PSD_COMMON_ID]
    else if Instrument='HC' then Variants := ['HC','H','HO',DRUM_PSD_COMMON_ID];
  end;
  Result := Default(TDrumPsdBinding); Result.State := dprBase;
  Result.Instrument := Instrument; Result.RequestedPart := Part; Result.TargetKind := TargetKind; Result.Stage := Stage;
  for Pass := 0 to 1 do begin
    Target := Part;
    if Pass=1 then begin
      if TargetKind<>'person' then Break;
      if Part='LA' then Target := 'RA' else if Part='RA' then Target := 'LA' else Break;
    end;
    for Variant in Variants do begin
      R := Candidate(Variant,Target,TargetKind,Stage);
      if R.State=dprBase then Continue;
      Result := R; Result.Instrument := Instrument; Result.RequestedPart := Part;
      if (R.State=dprDirect) and ((Variant<>Instrument) or (Target<>Part)) then Result.State := dprFallback;
      Exit;
    end;
  end;
  R := Candidate(Instrument,Part,TargetKind,-1);
  if R.State=dprBase then R := Candidate('',Part,TargetKind,-1);
  Result.ReferenceIndices := R.ReferenceIndices; Result.ActualPart := Part;
  if R.State=dprAmbiguous then Result.State := dprAmbiguous;
end;
procedure TMusicStudioDrumPsdRules.CompileBindings;
const Parts: array[0..6] of string = ('LA','RA','LL','RL','Back','Front','Character');
  Kinds: array[0..2] of string = ('person','instrument','effect');
  CommandIDs: array[0..8] of string = ('SDL','SDR','T1L','T1R','T2L','T2R','T3L','T3R','BD');
  Instruments: array[0..8] of string = ('SD','SD','T1','T1','T2','T2','T3','T3','BD');
  CommandParts: array[0..8] of string = ('LA','RA','LA','RA','LA','RA','LA','RA','RL');
  Defaults: array[0..8] of string = ('BD','SD','T1','T2','T3',DRUM_PSD_STICK_ID,DRUM_PSD_CRASH_ID,DRUM_PSD_RIDE_ID,'H');
var Keys: TDictionary<string,Boolean>; R: TDrumPsdReference; B: TDrumPsdBinding;
  Instrument,Part,TargetKind: string; I,Stage: Integer;
begin
  Keys := TDictionary<string,Boolean>.Create;
  try
    for R in FReferences do if R.Instrument<>'' then Keys.AddOrSetValue(R.Instrument,True);
    for Instrument in Defaults do Keys.AddOrSetValue(Instrument,True);
    Keys.AddOrSetValue('HO',True); Keys.AddOrSetValue('HC',True);
    for Instrument in Keys.Keys do for Part in Parts do for TargetKind in Kinds do for Stage := 0 to 9 do
      FBindings.Add(TargetKind+'|'+BindingKey(Instrument,Part,Stage),CompileBinding(Instrument,Part,TargetKind,Stage));
    for I := 0 to High(CommandIDs) do for Stage := 0 to 9 do begin
      B := Resolve(Instruments[I],CommandParts[I],Stage); B.CommandID := CommandIDs[I];
      FCommands.Add(CommandIDs[I]+'|'+IntToStr(Stage),B);
    end;
  finally Keys.Free; end;
end;
function TMusicStudioDrumPsdRules.Resolve(const Instrument,Part: string; Stage: Integer; const TargetKind: string): TDrumPsdBinding;
var Kind: string;
begin
  Kind := TargetKind;
  if Kind='' then begin
    if (Part='Back') or (Part='Front') then Kind := 'instrument' else Kind := 'person';
  end;
  if not FBindings.TryGetValue(Kind+'|'+BindingKey(Instrument,Part,Stage),Result) then begin
    Result := Default(TDrumPsdBinding); Result.State := dprBase;
    Result.Instrument := Instrument; Result.RequestedPart := Part; Result.TargetKind := Kind; Result.Stage := Stage;
  end;
  Result.ReferenceIndices := Copy(Result.ReferenceIndices);
end;
function TMusicStudioDrumPsdRules.ResolveCommand(const CommandID: string; Stage: Integer): TDrumPsdBinding;
begin
  if not FCommands.TryGetValue(CommandID+'|'+IntToStr(Stage),Result) then begin
    Result := Default(TDrumPsdBinding); Result.State := dprBase; Result.Stage := Stage;
    Result.CommandID := CommandID;
  end;
  Result.ReferenceIndices := Copy(Result.ReferenceIndices);
end;
function TMusicStudioDrumPsdRules.Clone: TMusicStudioDrumPsdRules;
var Pair: TPair<string,TDrumPsdBinding>; B: TDrumPsdBinding;
begin
  Result := TMusicStudioDrumPsdRules.Create;
  try
    Result.FReferences := Copy(FReferences); Result.FDiagnostics := Copy(FDiagnostics);
    Result.FHasDrumStructure := FHasDrumStructure; Result.FAnalysisCount := FAnalysisCount;
    for Pair in FBindings do begin B := Pair.Value; B.ReferenceIndices := Copy(B.ReferenceIndices); Result.FBindings.Add(Pair.Key,B); end;
    for Pair in FCommands do begin B := Pair.Value; B.ReferenceIndices := Copy(B.ReferenceIndices); Result.FCommands.Add(Pair.Key,B); end;
  except Result.Free; raise; end;
end;
function TMusicStudioDrumPsdRules.ReferenceAt(Index: Integer): TDrumPsdReference;
begin Result := FReferences[Index]; end;
function TMusicStudioDrumPsdRules.ReferenceCount: Integer;
begin Result := Length(FReferences); end;
function TMusicStudioDrumPsdRules.DiagnosticJSON: string;
const States: array[TDrumPsdResolution] of string = ('direct','fallback','base','ambiguous');
var Root,O: TJSONObject; A,LayerKeys: TJSONArray; R: TDrumPsdReference; S: string; Pair: TPair<string,TDrumPsdBinding>; I: Integer;
begin
  Root := TJSONObject.Create;
  try
    Root.AddPair('hasDrumStructure',TJSONBool.Create(FHasDrumStructure)); Root.AddPair('analysisCount',TJSONNumber.Create(FAnalysisCount));
    A := TJSONArray.Create; Root.AddPair('diagnostics',A); for S in FDiagnostics do A.Add(S);
    A := TJSONArray.Create; Root.AddPair('references',A);
    for R in FReferences do begin
      O := TJSONObject.Create; A.AddElement(O); O.AddPair('key',R.Layer.Key); O.AddPair('path',R.Layer.Path);
      O.AddPair('originalName',R.Layer.Name); O.AddPair('identifier',R.Identifier); O.AddPair('instrument',R.Instrument);
      O.AddPair('root',R.RootGroup); O.AddPair('part',R.Part); O.AddPair('stage',TJSONNumber.Create(R.Stage));
      O.AddPair('sourceIndex',TJSONNumber.Create(R.Layer.SourceIndex)); O.AddPair('exclusive',TJSONBool.Create(R.Exclusive));
      O.AddPair('alwaysVisible',TJSONBool.Create(R.AlwaysVisible)); O.AddPair('prefix',R.Prefix); O.AddPair('suffix',R.Suffix);
      O.AddPair('ambiguous',TJSONBool.Create(R.Ambiguous));
      O.AddPair('targetKind',R.TargetKind); O.AddPair('isBase',TJSONBool.Create(R.IsBase));
      O.AddPair('sourceVisible',TJSONBool.Create(R.Layer.Visible));
    end;
    A := TJSONArray.Create; Root.AddPair('bindings',A);
    for Pair in FBindings do begin
      O := TJSONObject.Create; A.AddElement(O); O.AddPair('key',Pair.Key); O.AddPair('state',States[Pair.Value.State]);
      O.AddPair('actualPart',Pair.Value.ActualPart); O.AddPair('requestedPart',Pair.Value.RequestedPart);
      LayerKeys := TJSONArray.Create; O.AddPair('layerKeys',LayerKeys);
      for I in Pair.Value.ReferenceIndices do LayerKeys.Add(FReferences[I].Layer.Key);
    end;
    A := TJSONArray.Create; Root.AddPair('commands',A);
    for Pair in FCommands do begin
      O := TJSONObject.Create; A.AddElement(O); O.AddPair('commandAndStage',Pair.Key);
      O.AddPair('state',States[Pair.Value.State]); O.AddPair('requestedPart',Pair.Value.RequestedPart);
      O.AddPair('actualPart',Pair.Value.ActualPart); LayerKeys := TJSONArray.Create; O.AddPair('layerKeys',LayerKeys);
      for I in Pair.Value.ReferenceIndices do LayerKeys.Add(FReferences[I].Layer.Key);
    end;
    Result := Root.ToJSON;
  finally Root.Free; end;
end;
end.
