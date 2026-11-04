// JSON adapter for reusable PSD mouth assignments and expression visibility.
// Unknown members and missing layer keys survive load/save for later relinking.
unit SYNC_MusicStudio_PsdLayerConfig;

interface

uses System.SysUtils, System.JSON, SYNC_MusicStudio_PsdLayers;

const
  MUSIC_STUDIO_MOUTH_NAMES: array[0..6] of string =
    ('normal','a','i','u','e','o','n');
  MUSIC_STUDIO_MOUTH_CAPTIONS: array[0..6] of string =
    ('通常 / 閉じ口','あ','い','う','え','お','ん');

function ParseMusicStudioPsdConfig(const Text: string): TJSONObject;
function MusicStudioPsdConfigObject(Config: TJSONObject; const Name: string): TJSONObject;
function MusicStudioMouthLayer(Config: TJSONObject; Index: Integer): string;
procedure MusicStudioAssignMouth(Config: TJSONObject; Index: Integer; const Key: string);
function BuildMusicStudioPsdOverrides(Document: TMusicStudioLayerDocument;
  Config: TJSONObject; MouthIndex: Integer = -1): TJSONObject;
// 合成用の値コピーに表情を重ねる。PSD本体・基本設定・母音割当は変更しない。
function BuildMusicStudioExpressionOverrides(Document: TMusicStudioLayerDocument;
  BaseConfig, Expression: TJSONObject): TJSONObject;

// 自動名候補は読込時に収集し、手動割当を優先する。同名別表情は表示中の親の枝から選ぶ。
function ResolveMusicStudioMouthConfig(Document: TMusicStudioLayerDocument; Config: TJSONObject): TJSONObject;
function MusicStudioSelectedMouth(Document: TMusicStudioLayerDocument; Config: TJSONObject; MouthIndex: Integer): string;
function MusicStudioCanSing(Document: TMusicStudioLayerDocument; Config: TJSONObject): Boolean;
// Missing settings stay off; malformed types are rejected before applying configuration.
function MusicStudioAnimateMouthSize(Config: TJSONObject): Boolean;
implementation
uses SYNC_MusicStudio_ArtLayerName;

function MusicStudioAnimateMouthSize(Config: TJSONObject): Boolean;
var Value: TJSONValue;
begin
  Result := False; if Config=nil then Exit;
  Value := Config.GetValue('animateMouthSize'); if Value=nil then Exit;
  if not (Value is TJSONBool) then raise Exception.Create('口のサイズ変化の設定が不正です。');
  Result := TJSONBool(Value).AsBoolean;
end;

function ResolveMusicStudioMouthConfig(Document: TMusicStudioLayerDocument; Config: TJSONObject): TJSONObject;
const Names: array[1..6] of string = ('あ','い','う','え','お','ん');
var I: Integer; Layer: TMusicStudioLayerInfo; Auto: TJSONObject; Keys: TJSONArray;
begin
  if Config=nil then Result := ParseMusicStudioPsdConfig('{}') else Result := Config.Clone as TJSONObject;
  if Document=nil then Exit;
  Auto := TJSONObject.Create; Result.RemovePair('autoMouthLayers').Free; Result.AddPair('autoMouthLayers',Auto);
  for I := 1 to 6 do begin
    Keys := TJSONArray.Create;
    for Layer in Document.Layers do if ParseLayerName(Layer.Name).DisplayName=Names[I] then Keys.Add(Layer.Key);
    Auto.AddPair(MUSIC_STUDIO_MOUTH_NAMES[I],Keys);
  end;
end;
function AutoMouth(Config: TJSONObject; Index: Integer): TJSONArray;
var Auto: TJSONValue;
begin
  Result := nil; if (Config=nil) or (Index<1) or (Index>6) then Exit;
  Auto := Config.GetValue('autoMouthLayers');
  if Auto is TJSONObject then if TJSONObject(Auto).GetValue(MUSIC_STUDIO_MOUTH_NAMES[Index]) is TJSONArray then
    Result := TJSONArray(TJSONObject(Auto).GetValue(MUSIC_STUDIO_MOUTH_NAMES[Index]));
end;
function MusicStudioSelectedMouth(Document: TMusicStudioLayerDocument; Config: TJSONObject; MouthIndex: Integer): string;
var Keys: TJSONArray; Key: TJSONValue; Visibility: TJSONObject;
begin
  Result := MusicStudioMouthLayer(Config,MouthIndex);
  if Document.HasLayer(Result) then Exit; Result := ''; Keys := AutoMouth(Config,MouthIndex); if Keys=nil then Exit;
  Visibility := MusicStudioPsdConfigObject(Config,'visibility');
  for Key in Keys do if (Key is TJSONString) and Document.LayerBranchVisible(Key.Value,Visibility) then Exit(Key.Value);
end;
function MusicStudioCanSing(Document: TMusicStudioLayerDocument; Config: TJSONObject): Boolean;
var Resolved: TJSONObject; I: Integer; Keys: TJSONArray;
begin
  Result := False; if Document=nil then Exit;
  Resolved := ResolveMusicStudioMouthConfig(Document,Config);
  try
    for I := 1 to 6 do if not Document.HasLayer(MusicStudioMouthLayer(Resolved,I)) then begin
      Keys := AutoMouth(Resolved,I); if (Keys=nil) or (Keys.Count=0) then Exit;
    end;
    Result := True;
  finally Resolved.Free; end;
end;
function MusicStudioPsdConfigObject(Config: TJSONObject; const Name: string): TJSONObject;
var Value: TJSONValue;
begin
  Value := Config.GetValue(Name);
  if Value=nil then begin Result := TJSONObject.Create; Config.AddPair(Name,Result); end
  else if Value is TJSONObject then Result := TJSONObject(Value)
  else raise Exception.Create('PSD設定の '+Name+' が不正です。');
end;

function ParseMusicStudioPsdConfig(const Text: string): TJSONObject;
var Value: TJSONValue; Pair: TJSONPair; I: Integer;
begin
  if Length(Text)>262144 then raise Exception.Create('PSD設定JSONが大きすぎます。');
  if Trim(Text)='' then Result := TJSONObject.Create
  else begin
    Value := TJSONObject.ParseJSONValue(Text);
    if not (Value is TJSONObject) then begin Value.Free; raise Exception.Create('PSD設定JSONが不正です。'); end;
    Result := TJSONObject(Value);
  end;
  try
    if Result.GetValue('version')=nil then Result.AddPair('version',TJSONNumber.Create(1));
    for Pair in MusicStudioPsdConfigObject(Result,'visibility') do
      if not (Pair.JsonValue is TJSONBool) then raise Exception.Create('PSDレイヤーの表示設定が不正です。');
    MusicStudioAnimateMouthSize(Result);
    MusicStudioPsdConfigObject(Result,'mouthLayers');
    for I := 0 to 6 do MusicStudioMouthLayer(Result,I);
  except Result.Free; raise; end;
end;

function MusicStudioMouthLayer(Config: TJSONObject; Index: Integer): string;
var Value: TJSONValue;
begin
  Result := ''; if (Config=nil) or (Index<0) or (Index>6) then Exit;
  Value := MusicStudioPsdConfigObject(Config,'mouthLayers').GetValue(MUSIC_STUDIO_MOUTH_NAMES[Index]);
  if Value=nil then Exit;
  if not (Value is TJSONString) then raise Exception.Create('PSD母音の割当が不正です。');
  Result := TJSONString(Value).Value;
end;

procedure MusicStudioAssignMouth(Config: TJSONObject; Index: Integer; const Key: string);
var Obj: TJSONObject; Pair: TJSONPair;
begin
  if (Config=nil) or (Index<0) or (Index>6) then Exit;
  Obj := MusicStudioPsdConfigObject(Config,'mouthLayers');
  Pair := Obj.RemovePair(MUSIC_STUDIO_MOUTH_NAMES[Index]); Pair.Free;
  if Key<>'' then Obj.AddPair(MUSIC_STUDIO_MOUTH_NAMES[Index],Key);
end;

function BuildMusicStudioPsdOverrides(Document: TMusicStudioLayerDocument;
  Config: TJSONObject; MouthIndex: Integer): TJSONObject;
var Value,AutoKey: TJSONValue; Pair: TJSONPair; Key, Selected: string; I: Integer; Keys: TJSONArray;
begin
  Result := TJSONObject.Create;
  try
    if Config<>nil then begin
      Value := Config.GetValue('visibility');
      if Value is TJSONObject then
        for Pair in TJSONObject(Value) do
          if Pair.JsonValue is TJSONBool then
            MusicStudioSetJsonBoolean(Result,Pair.JsonString.Value,TJSONBool(Pair.JsonValue).AsBoolean);
    end;
    if (Document=nil) or (MouthIndex<0) or (MouthIndex>6) then Exit;
    Selected := MusicStudioSelectedMouth(Document,Config,MouthIndex);
    if not Document.HasLayer(Selected) then Exit;
    for I := 0 to 6 do begin
      Key := MusicStudioMouthLayer(Config,I);
      if Document.HasLayer(Key) then MusicStudioSetJsonBoolean(Result,Key,False);
      Keys := AutoMouth(Config,I); if Keys<>nil then for AutoKey in Keys do
        if (AutoKey is TJSONString) and Document.HasLayer(AutoKey.Value) then MusicStudioSetJsonBoolean(Result,AutoKey.Value,False);
    end;
    Document.SelectLayerOverride(Result,Selected);
  except Result.Free; raise; end;
end;

function BuildMusicStudioExpressionOverrides(Document: TMusicStudioLayerDocument;
  BaseConfig, Expression: TJSONObject): TJSONObject;
var Config, Overrides, Visibility: TJSONObject; Pair: TJSONPair;
begin
  Config := TJSONObject(BaseConfig.Clone); Overrides := nil;
  try
    Overrides := BuildMusicStudioPsdOverrides(Document,BaseConfig,-1);
    Visibility := MusicStudioPsdConfigObject(Expression,'visibility');
    for Pair in Visibility do MusicStudioSetJsonBoolean(Overrides,Pair.JsonString.Value,TJSONBool(Pair.JsonValue).AsBoolean);
    for Pair in Visibility do if TJSONBool(Pair.JsonValue).AsBoolean then
      Document.SelectLayerOverride(Overrides,Pair.JsonString.Value);
    Config.RemovePair('visibility').Free; Config.AddPair('visibility',Overrides); Overrides := nil;
    Result := BuildMusicStudioPsdOverrides(Document,Config,0);
  finally Overrides.Free; Config.Free; end;
end;

end.
