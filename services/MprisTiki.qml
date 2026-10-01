pragma Singleton

import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Io
import QtQuick

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
        
    }

    property MprisPlayer trackedPlayer: null;
    property bool _manualPlayerSelection: false;
    property int _playbackStateVersion: 0;

    property var _playerGrace: ({});

    property bool __reverse: false;
    property var activeTrack;

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

