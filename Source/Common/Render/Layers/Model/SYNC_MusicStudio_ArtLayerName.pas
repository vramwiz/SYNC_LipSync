// Copied from AviUtl2PluginLib/Lib/PSDArtEditor/Core/ArtLayerName.pas.
// Read and render only through SYNC_MusicStudio_PsdLayers; source PSD files are never saved.
unit SYNC_MusicStudio_ArtLayerName;
interface
uses System.SysUtils;
type
  TArtLayerNameParts = record
    Prefix, DisplayName, Suffix: string;
  end;
function ParseLayerName(const Name: string): TArtLayerNameParts;
function IsAllowedExternalLayerName(const Original, Name: string): Boolean;
function RenameLayerDisplay(const Original, DisplayName: string): string;
function SetLayerPrefix(const Original, Prefix: string): string;
function SetLayerFlip(const Original, Suffix: string): string;
implementation
uses SYNC_MusicStudio_ArtDocument;
function FlipSuffix(const Name: string): string;
begin
  Result := '';
  if Name.EndsWith(':flipxy') then Result := ':flipxy'
  else if Name.EndsWith(':flipx') then Result := ':flipx'
  else if Name.EndsWith(':flipy') then Result := ':flipy';
end;
function ParseLayerName(const Name: string): TArtLayerNameParts;
var I: Integer; Body,S: string;
begin
  I := 1;
  while (I<=Length(Name)) and CharInSet(Name[I],['*','!']) do Inc(I);
  Result.Prefix := Copy(Name,1,I-1); Body := Copy(Name,I,MaxInt); Result.Suffix := '';
  // Preserve even an ambiguous legacy modifier chain on a plain text rename.
  repeat
    S := FlipSuffix(Body);
    if S='' then Break;
    Result.Suffix := S+Result.Suffix; SetLength(Body,Length(Body)-Length(S));
  until False;
  Result.DisplayName := Body;
end;
function IsAllowedExternalLayerName(const Original, Name: string): Boolean;
var BeforeParts,AfterParts: TArtLayerNameParts;
begin
  if Original=Name then Exit(True);
  BeforeParts := ParseLayerName(Original); AfterParts := ParseLayerName(Name);
  Result := (BeforeParts.DisplayName=AfterParts.DisplayName) and
    ((AfterParts.Prefix=BeforeParts.Prefix) or (AfterParts.Prefix='') or
      (AfterParts.Prefix='*') or (AfterParts.Prefix='!')) and
    ((AfterParts.Suffix=BeforeParts.Suffix) or (AfterParts.Suffix='') or
      (AfterParts.Suffix=':flipx') or (AfterParts.Suffix=':flipy') or
      (AfterParts.Suffix=':flipxy'));
end;
function RenameLayerDisplay(const Original, DisplayName: string): string;
var Parts: TArtLayerNameParts;
begin
  if Trim(DisplayName)='' then raise EArtFormat.Create('レイヤー名を入力してください。');
  if CharInSet(DisplayName[1],['*','!']) or (FlipSuffix(DisplayName)<>'') then
    raise EArtFormat.Create('修飾子は右クリックメニューで設定してください。');
  Parts := ParseLayerName(Original);
  Result := Parts.Prefix+DisplayName+Parts.Suffix;
end;
function SetLayerPrefix(const Original, Prefix: string): string;
var Parts: TArtLayerNameParts;
begin
  if (Prefix<>'') and (Prefix<>'*') and (Prefix<>'!') then raise EArtFormat.Create('Invalid prefix');
  Parts := ParseLayerName(Original); Result := Prefix+Parts.DisplayName+Parts.Suffix;
end;
function SetLayerFlip(const Original, Suffix: string): string;
var Parts: TArtLayerNameParts;
begin
  if (Suffix<>'') and (Suffix<>':flipx') and (Suffix<>':flipy') and (Suffix<>':flipxy') then
    raise EArtFormat.Create('Invalid flip suffix');
  Parts := ParseLayerName(Original); Result := Parts.Prefix+Parts.DisplayName+Suffix;
end;
end.
