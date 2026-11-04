unit SYNC_MusicStudio_Vowels;

// SongReader/Core/SongAIUEOとSongDataTrackの辞書・拗音/長音処理を演奏用に複製した。
// 読みの推測は行わず、辞書外文字は?として母音不明を明示する。
interface

function MusicStudioLyricVowels(const Lyric: string; const Previous: string = ''): string;

implementation

uses
  System.SysUtils;

function VowelForChar(Value: Char): Char;
begin
  if Pos(Value, 'あかさたなはまやらわがざだばぱぁゃアカサタナハマヤラワガザダバパァャaA') > 0 then Exit('a');
  if Pos(Value, 'いきしちにひみりぎじぢびぴぃイキシチニヒミリギジヂビピィiI') > 0 then Exit('i');
  if Pos(Value, 'うくすつぬふむゆるぐずづぶぷぅゅウクスツヌフムユルグズヅブプゥュヴuU') > 0 then Exit('u');
  if Pos(Value, 'えけせてねへめれげぜでべぺぇエケセテネヘメレゲゼデベペェeE') > 0 then Exit('e');
  if Pos(Value, 'おこそとのほもよろをごぞどぼぽぉょオコソトノホモヨロヲゴゾドボポォョoO') > 0 then Exit('o');
  if Pos(Value, 'んっンッnN') > 0 then Exit('n');
  Result := '?';
end;

function MusicStudioLyricVowels(const Lyric, Previous: string): string;
var
  I: Integer;
  Current, Last: Char;
  Source: string;
begin
  Result := '';
  Source := Trim(Lyric);
  Last := '?';
  if Previous <> '' then Last := Previous[Length(Previous)];
  I := 1;
  while I <= Length(Source) do
  begin
    Current := Source[I];
    if Pos(Current, 'ー－-') > 0 then
    begin
      if Last = '?' then Result := Result + '?' else Result := Result + Last;
      Inc(I);
      Continue;
    end;
    if (I < Length(Source)) and (Pos(Source[I + 1], 'ゃゅょぁぃぅぇぉャュョァィゥェォ') > 0) then
    begin
      Inc(I);
      Current := Source[I];
    end;
    Last := VowelForChar(Current);
    if not CharInSet(Current, [' ', #9, #13, #10]) then Result := Result + Last;
    Inc(I);
  end;
end;

end.
