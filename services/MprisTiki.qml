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

    function syncPlayerLists(){
        const rawList = Mpris.players.values;
        root.players = rawList;

        //lista sin duplicados de yt music u otros
        let deduplicated = [];
        //creo un set auxiliar para registrar esos players unicos
        let seenIdentities = new Set();

        for (let i = 0; i < rawList.length; i++){

            //recorro la lista de players y guardo sus propiedades
            //en una variable, y luego copio la id de ese player
            //en otra variable con la que opero luego
            let player = rawList[i];
            let id = player.identity ?? player.desktopEntry ?? "";

            //registro especificamente si el player es youtube music
            //porque a esos mamones les encanta duplicar sus signals
            let key;
            let isYtMusic = id.toLowerCase().includes("ytmusic") || id.toLowerCase().includes("youtube music")

            if (isYtMusic) {
                key = "YouTube Music";
            } else {
                key = id;
            }

            if (key !== "" && seenIdentities.has(key)) continue;
            if (key !== "") seenIdentities.add(key);

            deduplicated.push(player);
        }

        if (hasStructureChanged(root.displayPlayers, deduplicated)) {
            root.displayPlayers = deduplicated;
        }
    }
}

