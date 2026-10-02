pragma Singleton

import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Io
import QtQuick
import QtQml.Models

Scope {
    id: root;

    // lista de players sin filtrar, raw
    property list<MprisPlayer> players: []
    // lista filtrada
    property list<MprisPlayer> displayPlayers: []

    //conexion con la api
    Connections {
        target: Mpris.players
        function onValuesChanged() {
            root.syncPlayerLists();
        }
    }
    Component.onCompleted: {
        root.syncPlayerLists();
    }

    Connections {
        target: YtMusic
        function onMpvPlayerChanged(){
            root._updateMpvCache();
            root._rebuildPlayerList();
        }
        function onCurrentVideoIdChanged(){
            root._rebuildPlayerList();
        }
        function onCurrentTitleChanged(){
            root._rebuildPlayerList();
        }
    }

    Timer {
        id: _rebuildDebounce
        interval: 50
        repeat: false
        onTriggered: root._doRebuildPlayerList(false)
    }

    Timer {
        id: _emptyListGraceTimer
        interval: 1800
        repeat: false
        onTriggered: root._doRebuildPlayerList(true)
    }

    Timer {
        id: _streamMetadataRefresh
        interval: 120
        repeat: false
        onTriggered: {
            if (!_streamMetadataProc.running) {
                _streamMetadataProc.running = true
            }
        }
    }

    Process {
        id: _streamMetadataProc
        command: ["pw-dump"]
        stdout: StdioCollector { id: _streamMetadataCollector }
        onExited: (exitCode, _exitStatus) => {
            if (exitCode !== 0) return
            try{
                const data = JSON.parse(_streamMetadataCollector.text ?? "[]")
                const next = {}
                for (const item of data) {
                    if (item?.type !== "PipeWire:Interface:Node") continue
                    const props = item?.info?.props ?? {}
                    if (props["media.class"] !== "Stream/Output/Audio") continue
                    const id = Number(item?.id ?? 0);
                    if (!Number.isFinite(id) || id <= 0) continue
                    next[id] = {
                        appName: props["application.name"] ?? "",
                        appId: props["application.id"] ?? "",
                        binary: props["application.process.binary"] ?? "",
                        nodeName: props["node.name"] ?? "",
                        mediaName: props["media.name"] ?? ""
                    }
                }
                root._streamMetadataById = next
            } catch (e) {
                console.warn("[MprisController] Failed to parse PipeWire stream metadata: ", e)
            }
        }
    }

    function _rebuildPlayerList(): void {
        _rebuildDebounce.restart();
    }

    function _doRebuildPlayerList(forceEmpty: bool): void {
        let newlist = [];
        for (const player of Mpris.players.values) {
            if (isRealPlayer(player)) {
                newList.push(player);
            }
        }
        const allowEmpty = forceEmpty === true;
        if (!allowEmpty && newList.length === 0 && (displayPlayers?.length ?? 0 ) > 0) {
            _emptyListGraceTimer.restart();
            return;
        }
        if (newList.length > 0) {
            _emptyListGraceTimer.stop();
        }
        if (!_samePlayerOrder(newList, players)) {
            players = newList;
        }

        const nextDisplayPlayers = _filterYtMusicDuplicates(newList);
        if (!_samePlayerOrder(nextDisplayPlayers, displayPlayers)) displayPlayers = nextDisplayPlayers;

        if (trackedPlayer && !players.includes(trackedPlayer)) {
            _manualPlayerSelection = false;
            trackedPlayer = players[0] ?? null;
        }

    }

    function _samePlayerOrder(a, b): bool {
        if ((a?.length ?? 0 ) !== (b?.length ?? 0)) return false;
        for (let i = 0; i < a.length; i++) {
            if (a[i] !== b[i]) return false;
        }
        return true;
    }

    function isRealPlayer(player) {
        const name = player?.dbusName ?? "";
        if (!name) return false;

        const rawUrl = player?.metadata?.["xesam:url"] ?? "";
        const lowerUrl = rawUrl.toLowerCase();
        const lowerTitle = (player?.trackTitle ?? "").toLowerCase();
        const lowerAlbum = (player?.trackAlbum ?? "").toLowerCase();

        if (root._isBrowserPlayer(player) && root._isYoutubeUrl(rawUrl) && root._extractYoutubeVideoId(rawUrl).length === 0) {
            return false;
        }

        if (lowerUrl.includes("x.com") || lowerUrl.includes("twitter.com") 
            || lowerTitle.includes("x.com") || lowerTitle.includes("twitter.com")
            || lowerAlbum.includes ("x.com") || lowerAlbum.includes("twitter.com")) {
                return false;
            }

        const isBrowserPlayerName = name.includes("firefox") || name.includes("chrome") || name.includes("chromium") ||
        name.includes("brave") || name.includes("vivaldi") || name.includes("opera");
        if (isBrowserPlayerName) {
            if (lowerTitle.includes("on x:") || lowerTitle.includes("/ x")) {
                return false;
            }
        }

        if (name === "org.mpris.MediaPlayer2.mpv" || name.startsWith('org.mpris.MediaPlayer2.mpv.instance')) {
            if (YtMusic.mpvPlayer) return player === YtMusic.mpvPlayer;
            if (name === "org.mpris.MediaPlayer2.mpv" && _mpvInstanceCache.hasMpvInstance) return false;
            if (name.startsWith('org.mpris.MediaPlayer2.mpv.instance')) {
                const hasAnyMeta = !!(player.trackTitle || player.trackArtist || (player.metadata?.["xesam:url"] ?? ""));
                if (_mpvInstanceCache.hasMpvBase && !player.isPlaying && !hasAnyMeta) return false;
            }
        }

        if (name.startsWith("org.mpris.MediaPlayer2.playerctld")) return false;

        if (name.endsWith('.mpd') && !name.endsWith('MediaPlayer2.mpd')) return false;


    }

    function _updateMpvCache() {
        let hasMpvInstance = false;
        let hasMpvBase = false;
        for (const p of Mpris.players.values) {
            const name = p?.dbusName ?? "";
            if (name.startsWith("org.mpris.MediaPlayer2.mpv.instance")) hasMpvInstance = true;
            if (name === "org.mpris.MediaPlayer2.mpv") hasMpvBase = true;
        }
        _mpvInstanceCache = {hasMpvInstance, hasMpvBase};
    }

    function _isYoutubeUrl(url): bool {
        const  value = (url ?? "").toString().toLowerCase();
        return value.includes("youtube.com") || value.includes("youtu.be");
    }

    property MprisPlayer trackedPlayer: null;
    property bool _manualPlayerSelection: false;
    property int _playbackStateVersion: 0;

    property var _playerGrace: ({});

    property bool __reverse: false;
    property var activeTrack;

    property var _streamMetadataById: {if (name === "org.mpris.MediaPlayer2.mpv" || name.startsWith("org.mpris.MediaPlayer2.mpv.instance")) {
			if (YtMusic.mpvPlayer) return player === YtMusic.mpvPlayer;
			// Use cached values instead of iterating
			if (name === "org.mpris.MediaPlayer2.mpv" && _mpvInstanceCache.hasMpvInstance) return false;
			// Drop ghost mpv.instance entries when base mpv exists
			if (name.startsWith("org.mpris.MediaPlayer2.mpv.instance")) {
				const hasAnyMeta = !!(player.trackTitle || player.trackArtist || (player.metadata?.["xesam:url"] ?? ""));
				if (_mpvInstanceCache.hasMpvBase && !player.isPlaying && !hasAnyMeta) return false;
			}
		}}

    property var _mpvInstanceCache: ({ hasMpvInstance: false, hasMpvBase: false});

    signal trackChanged(reverse: bool);

    property MprisPlayer activePlayer: {

        const _ = _playbackStateVersion;
        const visiblePlayers = displayPlayers ?? [];
        const trackedVisible = visiblePlayers.includes(trackedPlayer) ? trackedPlayer : null;

        if (_manualPlayerSelection && trackedVisible) return trackedVisible;
        if (trackedVisible?.isPlaying) return trackedVisible;

        for (let i = 0; i < visiblePlayers.length; i++) {
            if (visiblePlayers[i]?.isPlaying) return visiblePlayers[i]; 
        }
        
        if (trackedVisible) return trackedVisible;
        if (visiblePlayers.length > 0) return visiblePlayers[0];
    }

    Instantiator {
        model: Mpris.players;

        Connections {
            required property MprisPlayer modelData;
            target: modelData;

            Component.onCompleted: {
                if (!root._manualPlayerSelection && isRealPlayer(modelData) && (root.trackedPlayer == null || modelData.isPlaying)) {
                    root.trackedPlayer = modelData;
                }

                root._updateMpvCache();
                root._rebuildPlayerList();
            }

            Component.onDestruction: {
                if (root.trackedPlayer === modelData) {
                    root.trackedPlayer = null;
                    root._manualPlayerSelection = false;
                }
                if (!root._manualPlayerSelection && (root.trackedPlayer == null || !root.trackedPlayer.isPlaying)) {
                    for (const player of Mpris.players.values) {
                        if (player.isPlaying) {
                            root.trackedPlayer = player;
                            break;
                        }
                        if (trackedPlayer == null && Mpris.players.values.length != 0) {
                            root.trackedPlayer = Mpris.players.values[0];
                        } 
                    }
                }

                Qt.callLater(() => {
                    root._updateMpvCache();
                    root._rebuildPlayerList();
                })
            }

            function onPlaybackStateChanged() {
                root._playbackStateVersion++;
                if (!root._manualPlayerSelection && modelData.isPlaying && root.trackedPlayer !== modelData && isRealPlayer(modelData)) {
                    root.trackedPlayer = modelData;
                }
                root._rebuildPlayerList();
            }

            function onTrackTitleChanged() {
                root._rebuildPlayerList();
            }

            function onTrackArtUrlChanged() {
                root._rebuildPlayerList();
            }
        }

        Connections {
            target: activePlayer;

            function onPostTrackChanged() {
                root.updateTrack();
            }

            function onTrackTitleChanged() {
                root.updateTrack();
                _streamMetadataRefresh.restart();
            }

            function onTrackArtistChanged() {
                root.updateTrack();
            }

            function onTrackAlbumChanged() {
                root.updateTrack();
            }

            function onTrackArtUrlChanged() {
                if ((root.activePlayer?.uniqueId ?? 0) === (root.activeTrack?.uniqueId ?? 0) && (root.activePlayer?.trackArtUrl ?? "") !== (root.activeTrack?.artUrl ?? "")) {
                    const r = root.__reverse;
                    root.updateTrack();
                    root.__reverse = r;
                }
            }
        }

        function updateTrack() {
            this.activeTrack = {
                uniqueId: this.activePlayer?.uniqueId ?? 0,
                artUrl: this.activePlayer?.trackArtUrl ?? "",
                title: this.activePlayer?.trackTitle || Translation.tr("Unknown title"),
                artist: this.activePlayer?.trackArtist || Translation.tr("Unknown artist"),
                album: this.activePlayer?.trackAlbum || Translation.tr("Unknown album")
            };

            this.trackChanged(__reverse);
            this.__reverse = false;
        }
    }
}

