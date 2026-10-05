extends Node
## Проверка версии игры при подключении к хозяину.
## ВАЖНО: набор методов этого узла никогда не меняется — иначе разные версии игры
## не смогут даже сообщить друг другу, что они разные (Godot сверяет методы узлов).

signal mismatch(host_version)
signal accepted            # у игрока: хозяин подтвердил, что версии совпадают
signal verified(peer)      # на сервере: версия этого игрока совпала

var version := ""


func check() -> void:
	rpc_id(1, "hello", version)


@rpc("any_peer", "call_remote", "reliable")
func hello(v: String) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if v == version:
		verified.emit(id)
		rpc_id(id, "reply", true, version)
		return
	rpc_id(id, "reply", false, version)
	get_tree().create_timer(1.0).timeout.connect(func() -> void:
		var peer := multiplayer.multiplayer_peer
		if peer is ENetMultiplayerPeer and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			(peer as ENetMultiplayerPeer).disconnect_peer(id))


@rpc("authority", "call_remote", "reliable")
func reply(ok: bool, host_version: String) -> void:
	if ok:
		accepted.emit()
	else:
		mismatch.emit(host_version)
