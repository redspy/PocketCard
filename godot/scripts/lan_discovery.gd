class_name LanDiscovery
extends Node
## 같은 Wi-Fi 의 게임 서버 찾기: 서버가 1초마다 UDP 8788 로 보내는 알림을 받는다.
## 알림: {"app":"pocketcard","protocol":1,"name":"PC이름","code":"123456","port":8787,"open":true,"addresses":[...]}
## 폰끼리 대전의 방장 폰도 같은 알림을 보낸다: kind "phone", port 8789

signal updated

const PORT := 8788
const STALE_SEC := 4.0

var games: Dictionary = {}      # "ip:port" -> {name, code, address, open, seen}
var bind_error := ""
var _udp := PacketPeerUDP.new()

func _ready() -> void:
	var err := _udp.bind(PORT, "0.0.0.0")
	if err != OK:
		bind_error = "알림 수신 포트(%d)를 열 수 없습니다 (%s)" % [PORT, error_string(err)]

func _exit_tree() -> void:
	_udp.close()

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var dirty := false
	while _udp.get_available_packet_count() > 0:
		var pkt := _udp.get_packet()
		var ip := _udp.get_packet_ip()
		var d = JSON.parse_string(pkt.get_string_from_utf8())
		if typeof(d) != TYPE_DICTIONARY or str(d.get("app", "")) != "pocketcard":
			continue
		var port := int(d.get("port", 8787))
		var key := "%s:%d" % [ip, port]
		games[key] = { "name": str(d.get("name", "PC")), "code": str(d.get("code", "")), "address": key,
			"open": bool(d.get("open", true)), "protocol": int(d.get("protocol", 0)), "kind": str(d.get("kind", "server")), "seen": now }
		dirty = true
	for k in games.keys():
		var g: Dictionary = games[k]
		if now - float(g["seen"]) > STALE_SEC:
			games.erase(k)
			dirty = true
	if dirty:
		updated.emit()
