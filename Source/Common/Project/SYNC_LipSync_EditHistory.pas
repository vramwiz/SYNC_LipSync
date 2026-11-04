unit SYNC_LipSync_EditHistory;

// 編集確定時の作品JSONを保持する。復元が成功したときだけUndo/Redoの位置を進める。

interface

uses System.Generics.Collections;

type
  TLipSyncEditHistory = class
  private
    FStates: TList<string>;
    FIndex: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    // 同じ状態は追加せず、分岐した編集で以降のRedo履歴を破棄する。
    procedure RecordState(const JSON: string);
    function CanStep(Delta: Integer): Boolean;
    function Target(Delta: Integer): string;
    procedure Accept(Delta: Integer);
  end;

implementation

constructor TLipSyncEditHistory.Create;
begin
  inherited;
  FStates := TList<string>.Create;
  FIndex := -1;
end;

destructor TLipSyncEditHistory.Destroy;
begin
  FStates.Free;
  inherited;
end;

procedure TLipSyncEditHistory.RecordState(const JSON: string);
begin
  if (FIndex>=0) and (FStates[FIndex]=JSON) then Exit;
  while FStates.Count>FIndex+1 do FStates.Delete(FStates.Count-1);
  FStates.Add(JSON);
  // 最初の状態と直近32回の編集を保存する。
  if FStates.Count>33 then FStates.Delete(0);
  FIndex := FStates.Count-1;
end;

function TLipSyncEditHistory.CanStep(Delta: Integer): Boolean;
begin
  Result := (FIndex+Delta>=0) and (FIndex+Delta<FStates.Count);
end;

function TLipSyncEditHistory.Target(Delta: Integer): string;
begin
  Result := FStates[FIndex+Delta];
end;

procedure TLipSyncEditHistory.Accept(Delta: Integer);
begin
  Inc(FIndex,Delta);
end;

end.

