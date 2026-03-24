import { Socket, Presence } from "phoenix"

document.addEventListener('DOMContentLoaded', () => {
    // ── Pre-check ─────────────────────────────────────────────────────────────
    
    // Only run socket logic on the actual room page
    if (!window.location.pathname.startsWith('/room:')) {
        return;
    }

    // ── Session state ─────────────────────────────────────────────────────────

    let username = sessionStorage.getItem('user_id');
    let roomCode = sessionStorage.getItem('room_id');
    
    // Redirect if no session
    if (!username || !roomCode) {
        window.location.href = "/";
        return;
    }

    // ── Persistent Player Identity ───────────────────────────────────────────
    // Generate a UUID-based player_id in sessionStorage so it survives refreshes.
    // This allows testing with multiple tabs in the same browser, as each new tab
    // will get its own isolated sessionStorage.
    let playerId = sessionStorage.getItem('player_id');
    if (!playerId) {
        playerId = crypto.randomUUID();
        sessionStorage.setItem('player_id', playerId);
    }

    // ── DOM Elements ──────────────────────────────────────────────────────────

    const elRoomCode = document.getElementById('room-code-display');
    const elPlayerCount = document.getElementById('player-count');
    const elPlayersList = document.getElementById('players-list');
    const elWordDisplay = document.getElementById('word-display');
    const elRoundDisplay = document.getElementById('round-display');
    const elTimerDisplay = document.getElementById('timer-display');
    const elChatMessages = document.getElementById('chat');
    const elMessageInput = document.getElementById('message-input');
    
    // Overlays
    const elOverlayWaiting = document.getElementById('overlay-waiting');
    const elWaitingMsg = document.getElementById('waiting-msg');
    const elBtnStartGame = document.getElementById('btn-start-game');
    const elOverlayWordSelect = document.getElementById('overlay-word-select');
    const elWordChoicesCont = document.getElementById('word-choices-container');
    const elOverlayGameOver = document.getElementById('overlay-game-over');
    const elFinalLeaderboard = document.getElementById('final-leaderboard');
    const elBtnPlayAgain = document.getElementById('btn-play-again');

    // Controls
    const elDrawingControls = document.getElementById('drawing-controls');
    const elBtnClearCanvas = document.getElementById('btn-clear-canvas');
    const colorPicker = document.getElementById('color-picker');
    const colorBtns = document.querySelectorAll('.color-btn');
    const brushSize = document.getElementById('brush-size');
    
    // Canvas
    const canvas = document.getElementById('drawing-canvas');
    const ctx = canvas.getContext('2d');

    // ── Game State ────────────────────────────────────────────────────────────

    let isMyTurn = false;
    let currentDrawer = null;
    let gameStatePlayers = [];
    
    // Constants matching backend
    const CANVAS_WIDTH = 800;
    const CANVAS_HEIGHT = 480;

    if (elRoomCode) elRoomCode.textContent = roomCode;

    // ── Initialization ────────────────────────────────────────────────────────

    // Connect socket
    const socket = new Socket("/socket", { params: { username, roomCode, player_id: playerId } });
    socket.connect();

    // Join room channel
    const channel = socket.channel(`room:${roomCode}`, { username, roomCode, player_id: playerId });

    // ── Drawing Logic ─────────────────────────────────────────────────────────

    let isDrawing = false;
    let lastX = 0;
    let lastY = 0;
    let strokeBatch = [];
    let batchInterval = null;

    // We keep internal canvas resolution fixed so coordinates sync across devices natively.
    // CSS scales the canvas on smaller screens visually.
    function getMousePos(e) {
        const rect = canvas.getBoundingClientRect();
        // Scale mouse coordinates to match internal canvas resolution
        const scaleX = canvas.width / rect.width;
        const scaleY = canvas.height / rect.height;
        return {
            x: (e.clientX - rect.left) * scaleX,
            y: (e.clientY - rect.top) * scaleY
        };
    }

    // Draw locally function
    function drawLine(x0, y0, x1, y1, color, width) {
        ctx.strokeStyle = color;
        ctx.lineWidth = width;
        ctx.lineJoin = "round";
        ctx.lineCap = "round";
        ctx.beginPath();
        ctx.moveTo(x0, y0);
        ctx.lineTo(x1, y1);
        ctx.stroke();
    }

    // Collect into batch
    function emitStroke(x0, y0, x1, y1) {
        const color = colorPicker.value;
        const width = Number(brushSize.value);
        
        // Push to array for batched sending
        strokeBatch.push({
            x0: Math.round(x0), 
            y0: Math.round(y0), 
            x1: Math.round(x1), 
            y1: Math.round(y1),
            c: color,
            w: width
        });
    }

    // Flush batch every 50ms
    function startBatchTimer() {
        if (!batchInterval) {
            batchInterval = setInterval(() => {
                if (strokeBatch.length > 0) {
                    channel.push("draw_batch", { strokes: strokeBatch });
                    strokeBatch = []; // Reset array
                }
            }, 50);
        }
    }

    function stopBatchTimer() {
        if (batchInterval) {
            clearInterval(batchInterval);
            batchInterval = null;
        }
        // Final flush
        if (strokeBatch.length > 0) {
            channel.push("draw_batch", { strokes: strokeBatch });
            strokeBatch = [];
        }
    }

    // Canvas Events
    function handlePointerDown(e) {
        // Only the drawer can draw
        if (!isMyTurn) return;
        
        isDrawing = true;
        const pos = getMousePos(e);
        lastX = pos.x;
        lastY = pos.y;
        startBatchTimer();
        
        // Draw a dot on click
        drawLine(lastX, lastY, lastX, lastY, colorPicker.value, brushSize.value);
        emitStroke(lastX, lastY, lastX, lastY);
        
        e.preventDefault(); // Prevent scrolling on touch
    }

    function handlePointerMove(e) {
        if (!isDrawing || !isMyTurn) return;
        
        const pos = getMousePos(e);
        drawLine(lastX, lastY, pos.x, pos.y, colorPicker.value, brushSize.value);
        emitStroke(lastX, lastY, pos.x, pos.y);
        
        lastX = pos.x;
        lastY = pos.y;
        e.preventDefault();
    }

    function handlePointerUp() {
        if (isDrawing) {
            isDrawing = false;
            stopBatchTimer();
        }
    }

    // Use Pointer Events for unified Mouse/Touch support
    canvas.addEventListener("pointerdown", handlePointerDown);
    canvas.addEventListener("pointermove", handlePointerMove);
    window.addEventListener("pointerup", handlePointerUp);

    // ── Tools UI ──────────────────────────────────────────────────────────────

    // Allow presets to update color picker
    colorBtns.forEach(btn => {
        btn.addEventListener("click", () => {
            colorPicker.value = btn.dataset.color;
        });
    });

    elBtnClearCanvas.addEventListener("click", () => {
        if (!isMyTurn) return;
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        channel.push("clear_canvas", {});
    });

    // ── Input & Controls ──────────────────────────────────────────────────────

    elBtnStartGame.addEventListener("click", () => {
        const roundsSelect = document.getElementById("rounds-select");
        const rounds = roundsSelect ? parseInt(roundsSelect.value) : 3;
        channel.push("start_game", { rounds: rounds });
    });

    elBtnPlayAgain.addEventListener("click", () => {
        const role = sessionStorage.getItem('user_role');
        if (role === "creator") {
            channel.push("return_to_lobby", {});
        } else {
            addChatSysLine("Only the room creator can restart the game.", true);
        }
    });

    elMessageInput.addEventListener("keypress", (e) => {
        if (e.key === "Enter") {
            const guess = elMessageInput.value.trim();
            if (!guess) return;

            // Don't let drawer submit guesses
            if (isMyTurn) {
                addChatSysLine("You are drawing! You can't guess.", true);
                elMessageInput.value = '';
                return;
            }

            channel.push("submit_guess", { guess: guess })
                .receive("ok", resp => {
                    if (resp.result === "already_guessed") {
                        addChatSysLine("You already guessed it! Shhh...", true);
                    } else if (resp.result === "correct") {
                        // User's own correct guess shown only to them in green
                        const div = document.createElement('div');
                        div.className = 'message correct';
                        div.style.color = 'var(--success-color)';
                        div.style.fontWeight = 'bold';
                        const myName = getPlayerName(playerId) || "You";
                        div.innerHTML = `⭐ <span class="sender">${escapeHTML(myName)}:</span>${escapeHTML(guess)}`;
                        appendChat(div);
                    }
                })
                .receive("error", err => {
                    console.error("Guess error:", err);
                });
                
            elMessageInput.value = '';
        }
    });

    // ── UI Updaters ──────────────────────────────────────────────────────────

    function updatePlayersSidebar() {
        elPlayerCount.textContent = gameStatePlayers.length;
        elPlayersList.innerHTML = '';
        
        // Sort: highest score first
        const sorted = [...gameStatePlayers].sort((a, b) => b.score - a.score);

        sorted.forEach(p => {
            const li = document.createElement('li');
            li.className = 'player-item';
            
            if (p.player_id === currentDrawer) {
                li.classList.add('is-drawer');
            }
            if (p.guessed) {
                li.classList.add('is-guessed');
            }
            if (p.connected === false) {
                li.classList.add('is-disconnected');
            }

            const isMe = p.player_id === playerId ? " (You)" : "";
            const displayName = p.username || p.player_id;

            li.innerHTML = `
                <div class="player-info">
                    <span class="player-name">${escapeHTML(displayName)}${escapeHTML(isMe)}</span>
                    <span class="player-score">${p.score} pts</span>
                </div>
                <div class="player-status">
                    ${p.player_id === currentDrawer ? '✏️' : ''}
                    ${p.guessed ? '✅' : ''}
                    ${p.connected === false ? '⏳' : ''}
                </div>
            `;
            elPlayersList.appendChild(li);
        });

        // Show Start Game and Rounds Dropdown to Creator if >= 2 players and in lobby
        const role = sessionStorage.getItem('user_role');
        const roundsContainer = document.getElementById("rounds-selector-container");
        
        if (role === "creator" && currentPhase === "lobby") {
            if (roundsContainer) roundsContainer.style.display = "flex";

            if (gameStatePlayers.length >= 2) {
                elBtnStartGame.style.display = "block";
                elWaitingMsg.textContent = "Ready to start!";
            } else {
                elBtnStartGame.style.display = "none";
                elWaitingMsg.textContent = "Waiting for more players (need 2)...";
            }
        } else {
            if (roundsContainer) roundsContainer.style.display = "none";
            elBtnStartGame.style.display = "none";
        }
    }

    // Copy Room Code logic
    elRoomCode.parentElement.title = "Click to copy!";
    elRoomCode.parentElement.addEventListener('click', () => {
        if (navigator.clipboard) {
            navigator.clipboard.writeText(roomCode).then(() => {
                const orig = elRoomCode.textContent;
                elRoomCode.textContent = "Copied!";
                setTimeout(() => elRoomCode.textContent = orig, 1500);
            });
        }
    });

    function addChatLine(name, text, isCorrect = false) {
        const div = document.createElement('div');
        div.className = 'message ' + (isCorrect ? 'correct' : 'wrong');
        div.innerHTML = `<span class="sender">${escapeHTML(name)}:</span>${escapeHTML(text)}`;
        appendChat(div);
    }

    function addChatSysLine(text, highlight = false) {
        const div = document.createElement('div');
        div.className = 'message system';
        if (highlight) div.style.color = 'var(--accent-color)';
        div.innerHTML = escapeHTML(text);
        appendChat(div);
    }

    function appendChat(node) {
        elChatMessages.appendChild(node);
        elChatMessages.scrollTop = elChatMessages.scrollHeight;
    }

    function escapeHTML(str) {
        if (!str) return '';
        return String(str).replace(/[&<>'"]/g, 
            tag => ({
                '&': '&amp;',
                '<': '&lt;',
                '>': '&gt;',
                "'": '&#39;',
                '"': '&quot;'
            }[tag] || tag));
    }

    function hideAllOverlays() {
        elOverlayWaiting.style.display = "none";
        elOverlayWordSelect.style.display = "none";
        elOverlayGameOver.style.display = "none";
    }

    function disableCanvasBlock() {
        elDrawingControls.style.display = "none";
        canvas.classList.add('disabled');
        elMessageInput.disabled = false;
        elMessageInput.placeholder = "Type your guess here...";
        isMyTurn = false;
    }

    function enableCanvasBlock() {
        elDrawingControls.style.display = "flex";
        canvas.classList.remove('disabled');
        elMessageInput.disabled = true;
        elMessageInput.placeholder = "Drawing... (Chat disabled in game)";
        isMyTurn = true;
    }

    function formatTime(seconds) {
        return seconds; // Keeping it simple as raw seconds for fast-paced game
    }

    // Resolve a player_id to a display-friendly username
    function getPlayerName(pid) {
        const p = gameStatePlayers.find(pl => pl.player_id === pid);
        return p ? p.username : pid;
    }

    // ── Channel Event Listeners ──────────────────────────────────────────────

    // State sync on join
    channel.on("game_state", state => {
        gameStatePlayers = state.players;
        currentDrawer = state.current_drawer;
        currentPhase = state.phase;
        updatePlayersSidebar();

        if (state.phase === "lobby") {
            elOverlayWaiting.style.display = "flex";
        } else if (state.phase === "word_select") {
            // we let the explicit "word_select" handle this if it's our turn
            if (currentDrawer !== playerId) {
                hideAllOverlays();
                elOverlayWaiting.style.display = "flex";
                const drawerName = getPlayerName(currentDrawer);
                elWaitingMsg.textContent = `${drawerName} is choosing a word...`;
                elBtnStartGame.style.display = "none";
            }
        } else if (state.phase === "drawing") {
            hideAllOverlays();
            if (state.current_drawer === playerId) enableCanvasBlock();
            else disableCanvasBlock();
        } else if (state.phase === "game_over") {
            elOverlayGameOver.style.display = "flex";
        }
    });

    channel.on("player_joined", payload => {
        addChatSysLine(`${payload.username} joined the room!`);
        gameStatePlayers = payload.players;
        updatePlayersSidebar();
    });

    channel.on("player_left", payload => {
        const name = payload.username || payload.player_id;
        addChatSysLine(`${name} left the room.`);
        gameStatePlayers = payload.players;
        updatePlayersSidebar();
    });

    // State sync on return to lobby
    channel.on("returned_to_lobby", payload => {
        currentPhase = "lobby";
        hideAllOverlays();
        elOverlayWaiting.style.display = "flex";
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        
        gameStatePlayers = payload.players;
        updatePlayersSidebar();
    });

    channel.on("game_started", payload => {
        currentPhase = "word_select"; // or drawing, doesn't matter as long as it isn't lobby
        window.maxRounds = payload.max_rounds || 3;
        addChatSysLine(`The game is starting! Round 1 / ${window.maxRounds}`);
        gameStatePlayers = payload.players;
        updatePlayersSidebar();
        ctx.clearRect(0, 0, canvas.width, canvas.height);
    });

    // Word selection choices
    channel.on("word_select", payload => {
        currentDrawer = payload.drawer;
        const max = window.maxRounds || 3;
        elRoundDisplay.textContent = `Round ${payload.round} / ${max}`;
        ctx.clearRect(0, 0, canvas.width, canvas.height); // clear from prev turn
        
        if (payload.drawer === playerId) {
            // I am the drawer! Show modal.
            hideAllOverlays();
            elOverlayWordSelect.style.display = "flex";
            elWordDisplay.textContent = "CHOOSE A WORD";
            
            elWordChoicesCont.innerHTML = "";
            payload.choices.forEach(word => {
                const btn = document.createElement("button");
                btn.className = "word-choice-btn";
                btn.textContent = word;
                btn.addEventListener("click", () => {
                    channel.push("select_word", { word: word });
                });
                elWordChoicesCont.appendChild(btn);
            });
            enableCanvasBlock();
        } else {
            // Someone else is drawing
            hideAllOverlays();
            elOverlayWaiting.style.display = "flex";
            const drawerName = getPlayerName(payload.drawer);
            elWaitingMsg.textContent = `${drawerName} is choosing a word...`;
            elBtnStartGame.style.display = "none";
            disableCanvasBlock();
        }
        updatePlayersSidebar();
    });

    channel.on("turn_started", payload => {
        hideAllOverlays();
        elWordDisplay.textContent = payload.word_hint; // Guesser gets string like "_ _ _"
        elTimerDisplay.textContent = formatTime(payload.time_left);
        currentDrawer = payload.drawer;
        
        // Reset local players guessed state
        gameStatePlayers.forEach(p => p.guessed = false);
        updatePlayersSidebar();
        
        if (currentDrawer !== playerId) {
            const drawerName = getPlayerName(currentDrawer);
            addChatSysLine(`${drawerName} is drawing!`, true);
        }
    });

    // Only pushed to the actual drawer
    channel.on("drawer_word", payload => {
        elWordDisplay.textContent = payload.word; // Show unmasked word
    });

    // Progressive word reveal — updates the hint for guessers
    channel.on("word_update", payload => {
        // Don't overwrite the drawer's full word view
        if (currentDrawer !== playerId) {
            elWordDisplay.textContent = payload.word_hint;
        }
    });

    // UX Feedback: announce the revealed letter
    channel.on("hint_revealed", payload => {
        if (currentDrawer !== playerId) {
            // Log in chat
            addChatSysLine(`Hint revealed: '${payload.letter.toUpperCase()}'`, true);

            // Show floating visual toast
            const elHintToast = document.getElementById("hint-toast");
            if (elHintToast) {
                elHintToast.textContent = `Hint: ${payload.letter.toUpperCase()}`;
                elHintToast.classList.add("show");
                
                // Clear existing timeout to prevent flicker on rapid reveals
                if (window.hintToastTimeout) clearTimeout(window.hintToastTimeout);
                
                window.hintToastTimeout = setTimeout(() => {
                    elHintToast.classList.remove("show");
                }, 2500);
            }
        }
    });

    channel.on("timer_tick", payload => {
        const time = payload.time_left;
        elTimerDisplay.textContent = formatTime(time);
        
        const parent = elTimerDisplay.parentElement;
        if (time <= 10 && time > 0) {
            parent.classList.add("urgent");
        } else {
            parent.classList.remove("urgent");
        }
    });

    // Drawing Sync
    channel.on("draw_batch", payload => {
        // Render batch
        payload.strokes.forEach(stroke => {
            drawLine(stroke.x0, stroke.y0, stroke.x1, stroke.y1, stroke.c, stroke.w);
        });
    });

    channel.on("clear_canvas", () => {
        ctx.clearRect(0, 0, canvas.width, canvas.height);
    });

    // Chat / Guesses
    channel.on("chat_message", payload => {
        addChatLine(payload.username || payload.player_id, payload.message, false);
    });

    channel.on("correct_guess", payload => {
        const guesserName = payload.username || payload.player_id;
        
        // Common message for everyone (including the guesser)
        const div = document.createElement('div');
        div.className = 'message system correct';
        div.style.color = 'var(--success-color)';
        div.style.fontWeight = 'bold';
        div.innerHTML = escapeHTML(`⭐ ${guesserName} guessed the word! (+${payload.points} pts)`);
        appendChat(div);
        
        gameStatePlayers = payload.players;
        updatePlayersSidebar();
        
        if (payload.player_id === playerId) {
            // I got it!
            elMessageInput.disabled = true;
            elMessageInput.placeholder = "You guessed it! Shh...";
        }
    });

    channel.on("turn_ended", payload => {
        currentPhase = "turn_end";
        hideAllOverlays();
        elOverlayWaiting.style.display = "flex";
        elBtnStartGame.style.display = "none";
        
        // Reveal word
        elWaitingMsg.innerHTML = `Turn ended!<br>The word was: <span style="color:var(--accent-color);">${escapeHTML(payload.word)}</span>`;
        elWordDisplay.textContent = payload.word;
        
        gameStatePlayers = payload.players;
        updatePlayersSidebar();
        addChatSysLine(`Turn over. The word was ${payload.word}`);
        disableCanvasBlock();
    });

    channel.on("game_over", payload => {
        currentPhase = "game_over";
        hideAllOverlays();
        elOverlayGameOver.style.display = "flex";
        
        // Hide Play Again button if not creator
        const role = sessionStorage.getItem('user_role');
        if (role !== "creator") {
            elBtnPlayAgain.style.display = "none";
        } else {
            elBtnPlayAgain.style.display = "block";
        }
        
        // Build final LB
        elFinalLeaderboard.innerHTML = '';
        payload.leaderboard.forEach((p, index) => {
            const div = document.createElement('div');
            div.className = 'lb-row' + (index === 0 ? ' winner' : '');
            const name = p.username || p.player_id || p.user_id;
            
            let icons = "";
            if (index === 0) icons = "👑 🏆";
            else if (index === 1) icons = "🥈";
            else if (index === 2) icons = "🥉";

            div.innerHTML = `
                <span class="lb-name">${index + 1}. ${escapeHTML(name)} ${icons}</span>
                <span class="lb-score">${p.score} pts</span>
            `;
            elFinalLeaderboard.appendChild(div);
        });
        
        addChatSysLine(`Game Over!`, true);
    });

    // ── Connect & Join ────────────────────────────────────────────────────────

    channel.join()
        .receive("ok", resp => { 
            console.log("Joined room successfully", resp);
        })
        .receive("error", resp => { 
            console.error("Unable to join", resp);
            alert("Room failed to connect. Redirecting to home.");
            window.location.href = "/";
        });
});