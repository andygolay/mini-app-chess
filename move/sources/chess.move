module chess::chess {
    use std::signer;
    use std::vector;
    use aptos_framework::timestamp;

    // ============ PIECE CONSTANTS ============
    const EMPTY: u8 = 0;
    const PAWN: u8 = 1;
    const KNIGHT: u8 = 2;
    const BISHOP: u8 = 3;
    const ROOK: u8 = 4;
    const QUEEN: u8 = 5;
    const KING: u8 = 6;

    // Color is stored in bit 3 (value 8)
    const WHITE: u8 = 0;
    const BLACK: u8 = 8;

    // Flags stored in bits 4-7
    const HAS_MOVED: u8 = 16;

    // ============ GAME STATUS ============
    const STATUS_ACTIVE: u8 = 0;
    const STATUS_WHITE_WIN: u8 = 1;
    const STATUS_BLACK_WIN: u8 = 2;
    const STATUS_DRAW: u8 = 3;
    const STATUS_STALEMATE: u8 = 4;

    // ============ ERROR CODES ============
    const E_GAME_NOT_FOUND: u64 = 1;
    const E_NOT_YOUR_TURN: u64 = 2;
    const E_INVALID_MOVE: u64 = 3;
    const E_GAME_OVER: u64 = 4;
    const E_INVALID_SQUARE: u64 = 5;
    const E_INVALID_PROMOTION: u64 = 6;
    const E_NO_PIECE: u64 = 7;
    const E_WRONG_COLOR: u64 = 8;
    const E_WOULD_BE_IN_CHECK: u64 = 9;
    const E_CANNOT_CLAIM_DRAW: u64 = 10;
    const E_NO_LEGAL_MOVES: u64 = 11;

    // ============ STRUCTS ============

    struct Move has store, drop, copy {
        from_square: u8,
        to_square: u8,
        promotion: u8,
        captured_piece: u8,
        is_castling: bool,
        is_en_passant: bool,
    }

    struct Game has key, drop {
        board: vector<u8>,
        is_white_turn: bool,
        status: u8,
        move_count: u64,
        moves: vector<Move>,
        white_king_pos: u8,
        black_king_pos: u8,
        last_pawn_double_move: u8,
        half_move_clock: u64,
        created_at: u64,
    }

    struct PlayerStats has key {
        wins: u64,
        losses: u64,
        draws: u64,
        total_points: u64,
        current_streak: u64,
        best_streak: u64,
        fastest_win_moves: u64,
        games_played: u64,
    }

    struct Leaderboard has key {
        top_players: vector<address>,
        player_points: vector<u64>,
    }

    // ============ INIT ============

    fun init_module(account: &signer) {
        move_to(account, Leaderboard {
            top_players: vector::empty<address>(),
            player_points: vector::empty<u64>(),
        });
    }

    // ============ ENTRY FUNCTIONS ============

    public entry fun new_game(account: &signer) acquires Game {
        let addr = signer::address_of(account);

        // Initialize player stats if first game
        if (!exists<PlayerStats>(addr)) {
            move_to(account, PlayerStats {
                wins: 0,
                losses: 0,
                draws: 0,
                total_points: 0,
                current_streak: 0,
                best_streak: 0,
                fastest_win_moves: 0,
                games_played: 0,
            });
        };

        // Remove existing game if any
        if (exists<Game>(addr)) {
            let _old_game = move_from<Game>(addr);
        };

        let board = init_board();
        move_to(account, Game {
            board,
            is_white_turn: true,
            status: STATUS_ACTIVE,
            move_count: 0,
            moves: vector::empty<Move>(),
            white_king_pos: 4,   // e1
            black_king_pos: 60,  // e8
            last_pawn_double_move: 255, // Invalid square = no en passant
            half_move_clock: 0,
            created_at: timestamp::now_microseconds(),
        });
    }

    public entry fun make_move(
        account: &signer,
        from_square: u8,
        to_square: u8,
        promotion: u8,
    ) acquires Game, PlayerStats, Leaderboard {
        let addr = signer::address_of(account);
        assert!(exists<Game>(addr), E_GAME_NOT_FOUND);

        let game = borrow_global_mut<Game>(addr);
        assert!(game.status == STATUS_ACTIVE, E_GAME_OVER);
        assert!(game.is_white_turn, E_NOT_YOUR_TURN);
        assert!(from_square < 64 && to_square < 64, E_INVALID_SQUARE);

        // Validate and execute player move (white)
        execute_validated_move(game, from_square, to_square, promotion, true);

        // Check for game end after player move
        if (game.status != STATUS_ACTIVE) {
            finalize_game(addr);
            return
        };

        // AI makes its move (black)
        let ai_move = generate_ai_move(game);
        execute_validated_move(game, ai_move.from_square, ai_move.to_square, ai_move.promotion, false);

        // Check for game end after AI move
        if (game.status != STATUS_ACTIVE) {
            finalize_game(addr);
        };
    }

    public entry fun resign(account: &signer) acquires Game, PlayerStats, Leaderboard {
        let addr = signer::address_of(account);
        assert!(exists<Game>(addr), E_GAME_NOT_FOUND);

        let game = borrow_global_mut<Game>(addr);
        assert!(game.status == STATUS_ACTIVE, E_GAME_OVER);

        game.status = STATUS_BLACK_WIN;
        finalize_game(addr);
    }

    public entry fun claim_draw(account: &signer) acquires Game, PlayerStats, Leaderboard {
        let addr = signer::address_of(account);
        assert!(exists<Game>(addr), E_GAME_NOT_FOUND);

        let game = borrow_global_mut<Game>(addr);
        assert!(game.status == STATUS_ACTIVE, E_GAME_OVER);

        let can_draw = game.half_move_clock >= 100 || is_insufficient_material(&game.board);
        assert!(can_draw, E_CANNOT_CLAIM_DRAW);

        game.status = STATUS_DRAW;
        finalize_game(addr);
    }

    // ============ VIEW FUNCTIONS ============

    #[view]
    public fun get_game(player: address): (vector<u8>, bool, u8, u64, u8, u8) acquires Game {
        if (!exists<Game>(player)) {
            return (vector::empty<u8>(), true, 0, 0, 255, 255)
        };
        let game = borrow_global<Game>(player);
        (game.board, game.is_white_turn, game.status, game.move_count, game.white_king_pos, game.black_king_pos)
    }

    #[view]
    public fun get_moves(player: address): vector<Move> acquires Game {
        if (!exists<Game>(player)) {
            return vector::empty<Move>()
        };
        let game = borrow_global<Game>(player);
        game.moves
    }

    #[view]
    public fun get_player_stats(player: address): (u64, u64, u64, u64, u64) acquires PlayerStats {
        if (!exists<PlayerStats>(player)) {
            return (0, 0, 0, 0, 0)
        };
        let stats = borrow_global<PlayerStats>(player);
        (stats.wins, stats.losses, stats.draws, stats.total_points, stats.games_played)
    }

    #[view]
    public fun get_leaderboard(): (vector<address>, vector<u64>) acquires Leaderboard {
        if (!exists<Leaderboard>(@chess)) {
            return (vector::empty<address>(), vector::empty<u64>())
        };
        let lb = borrow_global<Leaderboard>(@chess);
        (lb.top_players, lb.player_points)
    }

    #[view]
    public fun is_in_check(player: address): bool acquires Game {
        if (!exists<Game>(player)) {
            return false
        };
        let game = borrow_global<Game>(player);
        let king_pos = if (game.is_white_turn) { game.white_king_pos } else { game.black_king_pos };
        is_square_attacked(&game.board, king_pos, !game.is_white_turn)
    }

    #[view]
    public fun has_game(player: address): bool {
        exists<Game>(player)
    }

    // ============ INTERNAL FUNCTIONS ============

    fun init_board(): vector<u8> {
        let board = vector::empty<u8>();

        // Rank 1 (index 0-7): White pieces
        vector::push_back(&mut board, WHITE | ROOK);
        vector::push_back(&mut board, WHITE | KNIGHT);
        vector::push_back(&mut board, WHITE | BISHOP);
        vector::push_back(&mut board, WHITE | QUEEN);
        vector::push_back(&mut board, WHITE | KING);
        vector::push_back(&mut board, WHITE | BISHOP);
        vector::push_back(&mut board, WHITE | KNIGHT);
        vector::push_back(&mut board, WHITE | ROOK);

        // Rank 2 (index 8-15): White pawns
        let i = 0;
        while (i < 8) {
            vector::push_back(&mut board, WHITE | PAWN);
            i = i + 1;
        };

        // Ranks 3-6 (index 16-47): Empty squares
        i = 0;
        while (i < 32) {
            vector::push_back(&mut board, EMPTY);
            i = i + 1;
        };

        // Rank 7 (index 48-55): Black pawns
        i = 0;
        while (i < 8) {
            vector::push_back(&mut board, BLACK | PAWN);
            i = i + 1;
        };

        // Rank 8 (index 56-63): Black pieces
        vector::push_back(&mut board, BLACK | ROOK);
        vector::push_back(&mut board, BLACK | KNIGHT);
        vector::push_back(&mut board, BLACK | BISHOP);
        vector::push_back(&mut board, BLACK | QUEEN);
        vector::push_back(&mut board, BLACK | KING);
        vector::push_back(&mut board, BLACK | BISHOP);
        vector::push_back(&mut board, BLACK | KNIGHT);
        vector::push_back(&mut board, BLACK | ROOK);

        board
    }

    fun execute_validated_move(
        game: &mut Game,
        from: u8,
        to: u8,
        promotion: u8,
        is_white: bool,
    ) {
        let piece = *vector::borrow(&game.board, (from as u64));
        let piece_type = piece & 7;
        let piece_color = piece & 8;

        // Verify piece exists and correct color
        assert!(piece_type != EMPTY, E_NO_PIECE);
        let expected_color = if (is_white) { WHITE } else { BLACK };
        assert!(piece_color == expected_color, E_WRONG_COLOR);

        // Validate the move
        let is_valid = is_valid_move(game, from, to, promotion, is_white);
        assert!(is_valid, E_INVALID_MOVE);

        // Get target piece for capture tracking
        let target = *vector::borrow(&game.board, (to as u64));
        let captured = target & 7;

        // Check for special moves
        let is_castling = piece_type == KING && abs_diff(from % 8, to % 8) == 2;
        let is_en_passant = piece_type == PAWN && (to % 8) != (from % 8) && captured == EMPTY;

        // Execute the move
        let new_piece = if (promotion != 0 && piece_type == PAWN) {
            (if (is_white) { WHITE } else { BLACK }) | promotion | HAS_MOVED
        } else {
            piece | HAS_MOVED
        };

        // Update board
        *vector::borrow_mut(&mut game.board, (from as u64)) = EMPTY;
        *vector::borrow_mut(&mut game.board, (to as u64)) = new_piece;

        // Handle castling - move rook
        if (is_castling) {
            let row = from / 8;
            if (to > from) {
                // Kingside
                let rook_from = row * 8 + 7;
                let rook_to = row * 8 + 5;
                let rook = *vector::borrow(&game.board, (rook_from as u64));
                *vector::borrow_mut(&mut game.board, (rook_from as u64)) = EMPTY;
                *vector::borrow_mut(&mut game.board, (rook_to as u64)) = rook | HAS_MOVED;
            } else {
                // Queenside
                let rook_from = row * 8;
                let rook_to = row * 8 + 3;
                let rook = *vector::borrow(&game.board, (rook_from as u64));
                *vector::borrow_mut(&mut game.board, (rook_from as u64)) = EMPTY;
                *vector::borrow_mut(&mut game.board, (rook_to as u64)) = rook | HAS_MOVED;
            };
        };

        // Handle en passant - remove captured pawn
        if (is_en_passant) {
            let captured_pawn_pos = if (is_white) { to - 8 } else { to + 8 };
            *vector::borrow_mut(&mut game.board, (captured_pawn_pos as u64)) = EMPTY;
        };

        // Update king position if king moved
        if (piece_type == KING) {
            if (is_white) {
                game.white_king_pos = to;
            } else {
                game.black_king_pos = to;
            };
        };

        // Update en passant target
        if (piece_type == PAWN && abs_diff(from / 8, to / 8) == 2) {
            game.last_pawn_double_move = if (is_white) { from + 8 } else { from - 8 };
        } else {
            game.last_pawn_double_move = 255;
        };

        // Update half-move clock
        if (piece_type == PAWN || captured != EMPTY || is_en_passant) {
            game.half_move_clock = 0;
        } else {
            game.half_move_clock = game.half_move_clock + 1;
        };

        // Record move
        let move_record = Move {
            from_square: from,
            to_square: to,
            promotion,
            captured_piece: if (is_en_passant) { PAWN } else { captured },
            is_castling,
            is_en_passant,
        };
        vector::push_back(&mut game.moves, move_record);
        game.move_count = game.move_count + 1;

        // Switch turns
        game.is_white_turn = !is_white;

        // Check game status
        update_game_status(game);
    }

    fun is_valid_move(game: &Game, from: u8, to: u8, promotion: u8, is_white: bool): bool {
        let piece = *vector::borrow(&game.board, (from as u64));
        let piece_type = piece & 7;

        // Check basic piece movement
        let basic_valid = if (piece_type == PAWN) {
            is_valid_pawn_move(game, from, to, promotion, is_white)
        } else if (piece_type == KNIGHT) {
            is_valid_knight_move(from, to)
        } else if (piece_type == BISHOP) {
            is_valid_bishop_move(&game.board, from, to)
        } else if (piece_type == ROOK) {
            is_valid_rook_move(&game.board, from, to)
        } else if (piece_type == QUEEN) {
            is_valid_queen_move(&game.board, from, to)
        } else if (piece_type == KING) {
            is_valid_king_move(game, from, to, is_white)
        } else {
            false
        };

        if (!basic_valid) {
            return false
        };

        // Check target square doesn't have friendly piece
        let target = *vector::borrow(&game.board, (to as u64));
        let target_type = target & 7;
        if (target_type != EMPTY) {
            let target_color = target & 8;
            let my_color = if (is_white) { WHITE } else { BLACK };
            if (target_color == my_color) {
                return false
            };
        };

        // Simulate move and check if king would be in check
        !would_be_in_check(game, from, to, is_white)
    }

    fun is_valid_pawn_move(game: &Game, from: u8, to: u8, promotion: u8, is_white: bool): bool {
        let from_row = from / 8;
        let from_col = from % 8;
        let to_row = to / 8;
        let to_col = to % 8;

        let target = *vector::borrow(&game.board, (to as u64));
        let target_empty = (target & 7) == EMPTY;

        // Check promotion validity
        let promo_row = if (is_white) { 7u8 } else { 0u8 };
        if (to_row == promo_row) {
            if (promotion != QUEEN && promotion != ROOK && promotion != BISHOP && promotion != KNIGHT) {
                return false
            };
        } else if (promotion != 0) {
            return false
        };

        if (is_white) {
            // Single push forward
            if (to_col == from_col && to_row == from_row + 1 && target_empty) {
                return true
            };

            // Double push from start
            if (from_row == 1 && to_col == from_col && to_row == 3 && target_empty) {
                let middle = from + 8;
                let middle_piece = *vector::borrow(&game.board, (middle as u64));
                if ((middle_piece & 7) == EMPTY) {
                    return true
                };
            };

            // Capture diagonally
            if (to_row == from_row + 1 && abs_diff(to_col, from_col) == 1) {
                // Normal capture
                if (!target_empty) {
                    return true
                };
                // En passant
                if (to == game.last_pawn_double_move) {
                    return true
                };
            };
        } else {
            // Black moves down
            if (to_col == from_col && from_row > 0 && to_row == from_row - 1 && target_empty) {
                return true
            };

            if (from_row == 6 && to_col == from_col && to_row == 4 && target_empty) {
                let middle = from - 8;
                let middle_piece = *vector::borrow(&game.board, (middle as u64));
                if ((middle_piece & 7) == EMPTY) {
                    return true
                };
            };

            if (from_row > 0 && to_row == from_row - 1 && abs_diff(to_col, from_col) == 1) {
                if (!target_empty) {
                    return true
                };
                if (to == game.last_pawn_double_move) {
                    return true
                };
            };
        };

        false
    }

    fun is_valid_knight_move(from: u8, to: u8): bool {
        let from_row = from / 8;
        let from_col = from % 8;
        let to_row = to / 8;
        let to_col = to % 8;

        let row_diff = abs_diff(from_row, to_row);
        let col_diff = abs_diff(from_col, to_col);

        (row_diff == 2 && col_diff == 1) || (row_diff == 1 && col_diff == 2)
    }

    fun is_valid_bishop_move(board: &vector<u8>, from: u8, to: u8): bool {
        let from_row = from / 8;
        let from_col = from % 8;
        let to_row = to / 8;
        let to_col = to % 8;

        let row_diff = abs_diff(from_row, to_row);
        let col_diff = abs_diff(from_col, to_col);

        if (row_diff != col_diff || row_diff == 0) {
            return false
        };

        is_diagonal_clear(board, from, to)
    }

    fun is_valid_rook_move(board: &vector<u8>, from: u8, to: u8): bool {
        let from_row = from / 8;
        let from_col = from % 8;
        let to_row = to / 8;
        let to_col = to % 8;

        if (from_row != to_row && from_col != to_col) {
            return false
        };

        if (from == to) {
            return false
        };

        is_line_clear(board, from, to)
    }

    fun is_valid_queen_move(board: &vector<u8>, from: u8, to: u8): bool {
        is_valid_rook_move(board, from, to) || is_valid_bishop_move(board, from, to)
    }

    fun is_valid_king_move(game: &Game, from: u8, to: u8, is_white: bool): bool {
        let from_row = from / 8;
        let from_col = from % 8;
        let to_row = to / 8;
        let to_col = to % 8;

        let row_diff = abs_diff(from_row, to_row);
        let col_diff = abs_diff(from_col, to_col);

        // Normal king move
        if (row_diff <= 1 && col_diff <= 1 && (row_diff + col_diff) > 0) {
            return true
        };

        // Castling
        if (row_diff == 0 && col_diff == 2) {
            return is_valid_castling(game, from, to, is_white)
        };

        false
    }

    fun is_valid_castling(game: &Game, from: u8, to: u8, is_white: bool): bool {
        let king = *vector::borrow(&game.board, (from as u64));

        // King must not have moved
        if ((king & HAS_MOVED) != 0) {
            return false
        };

        let row = from / 8;
        let is_kingside = to > from;
        let rook_col = if (is_kingside) { 7u8 } else { 0u8 };
        let rook_pos = row * 8 + rook_col;

        let rook = *vector::borrow(&game.board, (rook_pos as u64));
        let rook_type = rook & 7;

        // Rook must exist and not have moved
        if (rook_type != ROOK || (rook & HAS_MOVED) != 0) {
            return false
        };

        // Check path is clear
        let start = if (is_kingside) { from + 1 } else { rook_pos + 1 };
        let end = if (is_kingside) { rook_pos } else { from };

        let sq = start;
        while (sq < end) {
            let piece = *vector::borrow(&game.board, (sq as u64));
            if ((piece & 7) != EMPTY) {
                return false
            };
            sq = sq + 1;
        };

        // King cannot be in check
        if (is_square_attacked(&game.board, from, !is_white)) {
            return false
        };

        // King cannot pass through check
        let middle = if (is_kingside) { from + 1 } else { from - 1 };
        if (is_square_attacked(&game.board, middle, !is_white)) {
            return false
        };

        // King cannot end in check
        if (is_square_attacked(&game.board, to, !is_white)) {
            return false
        };

        true
    }

    fun is_diagonal_clear(board: &vector<u8>, from: u8, to: u8): bool {
        let from_row = (from / 8) as u64;
        let from_col = (from % 8) as u64;
        let to_row = (to / 8) as u64;
        let to_col = (to % 8) as u64;

        let row_dir: u64 = if (to_row > from_row) { 1 } else { 0 };
        let row_neg = to_row < from_row;
        let col_dir: u64 = if (to_col > from_col) { 1 } else { 0 };
        let col_neg = to_col < from_col;

        let curr_row = if (row_neg) { from_row - 1 } else { from_row + row_dir };
        let curr_col = if (col_neg) { from_col - 1 } else { from_col + col_dir };

        while (curr_row != to_row || curr_col != to_col) {
            let sq = curr_row * 8 + curr_col;
            let piece = *vector::borrow(board, sq);
            if ((piece & 7) != EMPTY) {
                return false
            };

            if (row_neg) { curr_row = curr_row - 1; } else { curr_row = curr_row + row_dir; };
            if (col_neg) { curr_col = curr_col - 1; } else { curr_col = curr_col + col_dir; };
        };

        true
    }

    fun is_line_clear(board: &vector<u8>, from: u8, to: u8): bool {
        let from_row = from / 8;
        let from_col = from % 8;
        let to_row = to / 8;
        let to_col = to % 8;

        if (from_row == to_row) {
            // Horizontal
            let start = if (from_col < to_col) { from_col + 1 } else { to_col + 1 };
            let end = if (from_col < to_col) { to_col } else { from_col };

            let col = start;
            while (col < end) {
                let sq = from_row * 8 + col;
                let piece = *vector::borrow(board, (sq as u64));
                if ((piece & 7) != EMPTY) {
                    return false
                };
                col = col + 1;
            };
        } else {
            // Vertical
            let start = if (from_row < to_row) { from_row + 1 } else { to_row + 1 };
            let end = if (from_row < to_row) { to_row } else { from_row };

            let row = start;
            while (row < end) {
                let sq = row * 8 + from_col;
                let piece = *vector::borrow(board, (sq as u64));
                if ((piece & 7) != EMPTY) {
                    return false
                };
                row = row + 1;
            };
        };

        true
    }

    fun is_square_attacked(board: &vector<u8>, square: u8, by_white: bool): bool {
        let attacker_color = if (by_white) { WHITE } else { BLACK };

        let i: u8 = 0;
        while (i < 64) {
            let piece = *vector::borrow(board, (i as u64));
            let piece_type = piece & 7;
            let piece_color = piece & 8;

            if (piece_type != EMPTY && piece_color == attacker_color) {
                if (can_attack(board, i, square, piece_type, by_white)) {
                    return true
                };
            };
            i = i + 1;
        };

        false
    }

    fun can_attack(board: &vector<u8>, from: u8, to: u8, piece_type: u8, is_white: bool): bool {
        if (piece_type == PAWN) {
            let from_row = from / 8;
            let from_col = from % 8;
            let to_row = to / 8;
            let to_col = to % 8;

            if (abs_diff(from_col, to_col) != 1) {
                return false
            };

            if (is_white) {
                return to_row == from_row + 1
            } else {
                return from_row > 0 && to_row == from_row - 1
            }
        } else if (piece_type == KNIGHT) {
            return is_valid_knight_move(from, to)
        } else if (piece_type == BISHOP) {
            return is_valid_bishop_move(board, from, to)
        } else if (piece_type == ROOK) {
            return is_valid_rook_move(board, from, to)
        } else if (piece_type == QUEEN) {
            return is_valid_queen_move(board, from, to)
        } else if (piece_type == KING) {
            let row_diff = abs_diff(from / 8, to / 8);
            let col_diff = abs_diff(from % 8, to % 8);
            return row_diff <= 1 && col_diff <= 1 && (row_diff + col_diff) > 0
        };

        false
    }

    fun would_be_in_check(game: &Game, from: u8, to: u8, is_white: bool): bool {
        // Create a copy of the board and simulate the move
        let temp_board = game.board;
        let piece = *vector::borrow(&temp_board, (from as u64));
        let piece_type = piece & 7;

        *vector::borrow_mut(&mut temp_board, (from as u64)) = EMPTY;
        *vector::borrow_mut(&mut temp_board, (to as u64)) = piece;

        // Handle en passant capture
        if (piece_type == PAWN && (to % 8) != (from % 8)) {
            let target = *vector::borrow(&game.board, (to as u64));
            if ((target & 7) == EMPTY && to == game.last_pawn_double_move) {
                let captured_pos = if (is_white) { to - 8 } else { to + 8 };
                *vector::borrow_mut(&mut temp_board, (captured_pos as u64)) = EMPTY;
            };
        };

        // Find king position
        let king_pos = if (is_white) {
            if (piece_type == KING) { to } else { game.white_king_pos }
        } else {
            if (piece_type == KING) { to } else { game.black_king_pos }
        };

        is_square_attacked(&temp_board, king_pos, !is_white)
    }

    fun update_game_status(game: &mut Game) {
        let is_white = game.is_white_turn;
        let has_legal_move = has_any_legal_move(game, is_white);

        if (!has_legal_move) {
            let king_pos = if (is_white) { game.white_king_pos } else { game.black_king_pos };
            let in_check = is_square_attacked(&game.board, king_pos, !is_white);

            if (in_check) {
                // Checkmate
                game.status = if (is_white) { STATUS_BLACK_WIN } else { STATUS_WHITE_WIN };
            } else {
                // Stalemate
                game.status = STATUS_STALEMATE;
            };
            return
        };

        // Check for draw conditions
        if (game.half_move_clock >= 100) {
            game.status = STATUS_DRAW;
            return
        };

        if (is_insufficient_material(&game.board)) {
            game.status = STATUS_DRAW;
        };
    }

    fun has_any_legal_move(game: &Game, is_white: bool): bool {
        let my_color = if (is_white) { WHITE } else { BLACK };

        let from: u8 = 0;
        while (from < 64) {
            let piece = *vector::borrow(&game.board, (from as u64));
            let piece_color = piece & 8;

            if ((piece & 7) != EMPTY && piece_color == my_color) {
                let to: u8 = 0;
                while (to < 64) {
                    if (is_valid_move(game, from, to, 0, is_white)) {
                        return true
                    };
                    // Check promotions for pawns
                    let piece_type = piece & 7;
                    let to_row = to / 8;
                    let promo_row = if (is_white) { 7u8 } else { 0u8 };
                    if (piece_type == PAWN && to_row == promo_row) {
                        if (is_valid_move(game, from, to, QUEEN, is_white)) {
                            return true
                        };
                    };
                    to = to + 1;
                };
            };
            from = from + 1;
        };

        false
    }

    fun is_insufficient_material(board: &vector<u8>): bool {
        let white_knights: u64 = 0;
        let white_bishops: u64 = 0;
        let black_knights: u64 = 0;
        let black_bishops: u64 = 0;
        let has_major_or_pawn = false;

        let i: u64 = 0;
        while (i < 64) {
            let piece = *vector::borrow(board, i);
            let piece_type = piece & 7;
            let is_white_piece = (piece & 8) == 0;

            if (piece_type == PAWN || piece_type == ROOK || piece_type == QUEEN) {
                has_major_or_pawn = true;
            } else if (piece_type == KNIGHT) {
                if (is_white_piece) { white_knights = white_knights + 1; }
                else { black_knights = black_knights + 1; };
            } else if (piece_type == BISHOP) {
                if (is_white_piece) { white_bishops = white_bishops + 1; }
                else { black_bishops = black_bishops + 1; };
            };
            i = i + 1;
        };

        if (has_major_or_pawn) {
            return false
        };

        // K vs K
        let white_minor = white_knights + white_bishops;
        let black_minor = black_knights + black_bishops;

        if (white_minor == 0 && black_minor == 0) {
            return true
        };

        // K+B vs K or K+N vs K
        if ((white_minor == 1 && black_minor == 0) || (white_minor == 0 && black_minor == 1)) {
            return true
        };

        false
    }

    // ============ AI LOGIC ============
    // 2-ply minimax with alpha-beta style pruning
    // Evaluates AI move, then considers best human response

    const SCORE_OFFSET: u64 = 100000; // Offset to handle "negative" scores with u64

    fun generate_ai_move(game: &Game): Move {
        let best_from: u8 = 0;
        let best_to: u8 = 0;
        let best_promo: u8 = 0;
        let best_score: u64 = 0;
        let found_move = false;

        // Generate all legal moves for black
        let from: u8 = 0;
        while (from < 64) {
            let piece = *vector::borrow(&game.board, (from as u64));
            let piece_color = piece & 8;

            if ((piece & 7) != EMPTY && piece_color == BLACK) {
                let to: u8 = 0;
                while (to < 64) {
                    let piece_type = piece & 7;
                    let to_row = to / 8;

                    let promos = if (piece_type == PAWN && to_row == 0) {
                        vector[QUEEN, ROOK, BISHOP, KNIGHT]
                    } else {
                        vector[0u8]
                    };

                    let p = 0;
                    while (p < vector::length(&promos)) {
                        let promo = *vector::borrow(&promos, p);

                        if (is_valid_move(game, from, to, promo, false)) {
                            // Evaluate this move using minimax
                            let score = evaluate_ai_move_with_response(game, from, to, promo);

                            // Small deterministic tiebreaker (much smaller than before)
                            let tiebreaker = ((from as u64) + (to as u64) * 3 + game.move_count) % 10;
                            let adjusted_score = score + tiebreaker;

                            if (!found_move || adjusted_score > best_score) {
                                best_score = adjusted_score;
                                best_from = from;
                                best_to = to;
                                best_promo = promo;
                                found_move = true;
                            };
                        };
                        p = p + 1;
                    };
                    to = to + 1;
                };
            };
            from = from + 1;
        };

        assert!(found_move, E_NO_LEGAL_MOVES);

        Move {
            from_square: best_from,
            to_square: best_to,
            promotion: best_promo,
            captured_piece: 0,
            is_castling: false,
            is_en_passant: false,
        }
    }

    // Evaluate AI move considering best human response (2-ply minimax)
    fun evaluate_ai_move_with_response(game: &Game, from: u8, to: u8, promo: u8): u64 {
        // Make the AI move on a temp board
        let temp_board = game.board;
        let piece = *vector::borrow(&temp_board, (from as u64));
        let piece_type = piece & 7;
        let captured = *vector::borrow(&temp_board, (to as u64)) & 7;

        // Execute move
        let new_piece = if (promo != 0) { BLACK | promo | HAS_MOVED } else { piece | HAS_MOVED };
        *vector::borrow_mut(&mut temp_board, (from as u64)) = EMPTY;
        *vector::borrow_mut(&mut temp_board, (to as u64)) = new_piece;

        // Handle castling
        let is_castling = piece_type == KING && abs_diff(from % 8, to % 8) == 2;
        if (is_castling) {
            let row = from / 8;
            if (to > from) {
                let rook = *vector::borrow(&temp_board, ((row * 8 + 7) as u64));
                *vector::borrow_mut(&mut temp_board, ((row * 8 + 7) as u64)) = EMPTY;
                *vector::borrow_mut(&mut temp_board, ((row * 8 + 5) as u64)) = rook | HAS_MOVED;
            } else {
                let rook = *vector::borrow(&temp_board, ((row * 8) as u64));
                *vector::borrow_mut(&mut temp_board, ((row * 8) as u64)) = EMPTY;
                *vector::borrow_mut(&mut temp_board, ((row * 8 + 3) as u64)) = rook | HAS_MOVED;
            };
        };

        // Handle en passant
        let is_en_passant = piece_type == PAWN && (to % 8) != (from % 8) && captured == EMPTY;
        if (is_en_passant) {
            *vector::borrow_mut(&mut temp_board, ((to + 8) as u64)) = EMPTY;
        };

        // Update king position
        let new_black_king = if (piece_type == KING) { to } else { game.black_king_pos };

        // Immediate position evaluation after AI move
        let position_score = evaluate_position(&temp_board, new_black_king, game.white_king_pos);

        // BIG bonus for captures (MVV-LVA: Most Valuable Victim - Least Valuable Attacker)
        let capture_bonus: u64 = 0;
        if (captured != EMPTY) {
            // High bonus for captures, extra if attacking with lower value piece
            capture_bonus = get_piece_value(captured) * 10;
            let attacker_value = get_piece_value(piece_type);
            if (attacker_value < get_piece_value(captured)) {
                capture_bonus = capture_bonus + 500; // Good trade
            };
        };

        // Check bonus
        let gives_check = is_square_attacked(&temp_board, game.white_king_pos, false);
        let check_bonus: u64 = if (gives_check) { 300 } else { 0 };

        // CRITICAL: Check if the moved piece is safe (not hanging)
        let piece_safe_bonus: u64 = 0;
        let piece_is_attacked = is_square_attacked(&temp_board, to, true);
        let piece_is_defended = is_square_attacked(&temp_board, to, false);

        if (piece_is_attacked) {
            if (!piece_is_defended) {
                // Piece is hanging! Big penalty
                let hanging_penalty = get_piece_value(if (promo != 0) { promo } else { piece_type }) * 8;
                if (position_score > hanging_penalty) {
                    return position_score - hanging_penalty + capture_bonus + check_bonus
                } else {
                    return capture_bonus + check_bonus // Avoid underflow
                }
            } else {
                // Piece is attacked but defended - check if trade is good
                let my_value = get_piece_value(if (promo != 0) { promo } else { piece_type });
                let attacker_value = get_lowest_attacker_value(&temp_board, to, true);
                if (attacker_value < my_value) {
                    // Bad trade possible - penalty
                    let trade_penalty = (my_value - attacker_value) * 5;
                    if (position_score > trade_penalty) {
                        return position_score - trade_penalty + capture_bonus + check_bonus
                    };
                };
            };
        } else {
            piece_safe_bonus = 100; // Bonus for safe square
        };

        // Consider best human response (1-ply lookahead for opponent)
        let human_threat = evaluate_best_human_response(&temp_board, game.white_king_pos, new_black_king);

        // Final score: position + bonuses - opponent's best response threat
        let base = position_score + capture_bonus + check_bonus + piece_safe_bonus;
        if (base > human_threat) {
            base - human_threat
        } else {
            1 // Avoid zero/underflow, this is a bad move
        }
    }

    // Find the best response white can make and return its threat value
    fun evaluate_best_human_response(board: &vector<u8>, _white_king: u8, black_king: u8): u64 {
        let max_threat: u64 = 0;

        let from: u8 = 0;
        while (from < 64) {
            let piece = *vector::borrow(board, (from as u64));
            let piece_type = piece & 7;
            let piece_color = piece & 8;

            if (piece_type != EMPTY && piece_color == WHITE) {
                let to: u8 = 0;
                while (to < 64) {
                    // Quick validation (no full game state, simplified)
                    if (can_piece_reach(board, from, to, piece_type, true)) {
                        let target = *vector::borrow(board, (to as u64));
                        let target_type = target & 7;
                        let target_color = target & 8;

                        // Skip if capturing own piece
                        if (target_type != EMPTY && target_color == WHITE) {
                            to = to + 1;
                            continue
                        };

                        // Evaluate threat of this response
                        let threat: u64 = 0;

                        // Capture threat
                        if (target_type != EMPTY && target_color == BLACK) {
                            threat = threat + get_piece_value(target_type) * 8;

                            // Check if our piece is defended
                            if (!is_square_attacked(board, to, false)) {
                                threat = threat + get_piece_value(target_type) * 4; // Extra for undefended
                            };
                        };

                        // Check threat
                        if (target_type == EMPTY || target_color == BLACK) {
                            // Simulate human move
                            let temp = *board;
                            *vector::borrow_mut(&mut temp, (from as u64)) = EMPTY;
                            *vector::borrow_mut(&mut temp, (to as u64)) = piece;

                            if (is_square_attacked(&temp, black_king, true)) {
                                threat = threat + 200; // Check is dangerous
                            };
                        };

                        if (threat > max_threat) {
                            max_threat = threat;
                        };
                    };
                    to = to + 1;
                };
            };
            from = from + 1;
        };

        max_threat
    }

    // Check if piece can reach target (simplified, without full legality check)
    fun can_piece_reach(board: &vector<u8>, from: u8, to: u8, piece_type: u8, is_white: bool): bool {
        if (from == to) return false;

        let from_row = from / 8;
        let from_col = from % 8;
        let to_row = to / 8;
        let to_col = to % 8;
        let row_diff = abs_diff(from_row, to_row);
        let col_diff = abs_diff(from_col, to_col);

        if (piece_type == PAWN) {
            if (is_white) {
                if (col_diff == 1 && to_row == from_row + 1) return true; // Capture
                if (col_diff == 0 && to_row == from_row + 1) {
                    let target = *vector::borrow(board, (to as u64));
                    return (target & 7) == EMPTY
                };
            } else {
                if (col_diff == 1 && from_row > 0 && to_row == from_row - 1) return true;
                if (col_diff == 0 && from_row > 0 && to_row == from_row - 1) {
                    let target = *vector::borrow(board, (to as u64));
                    return (target & 7) == EMPTY
                };
            };
            return false
        } else if (piece_type == KNIGHT) {
            return (row_diff == 2 && col_diff == 1) || (row_diff == 1 && col_diff == 2)
        } else if (piece_type == BISHOP) {
            return row_diff == col_diff && row_diff > 0 && is_diagonal_clear(board, from, to)
        } else if (piece_type == ROOK) {
            return (row_diff == 0 || col_diff == 0) && (row_diff + col_diff > 0) && is_line_clear(board, from, to)
        } else if (piece_type == QUEEN) {
            if (row_diff == col_diff && row_diff > 0) return is_diagonal_clear(board, from, to);
            if ((row_diff == 0 || col_diff == 0) && (row_diff + col_diff > 0)) return is_line_clear(board, from, to);
            return false
        } else if (piece_type == KING) {
            return row_diff <= 1 && col_diff <= 1
        };

        false
    }

    // Get the value of the lowest value attacker on a square
    fun get_lowest_attacker_value(board: &vector<u8>, square: u8, by_white: bool): u64 {
        let attacker_color = if (by_white) { WHITE } else { BLACK };
        let lowest: u64 = 10000; // Higher than any piece

        let i: u8 = 0;
        while (i < 64) {
            let piece = *vector::borrow(board, (i as u64));
            let piece_type = piece & 7;
            let piece_color = piece & 8;

            if (piece_type != EMPTY && piece_color == attacker_color) {
                if (can_attack(board, i, square, piece_type, by_white)) {
                    let value = get_piece_value(piece_type);
                    if (value < lowest) {
                        lowest = value;
                    };
                };
            };
            i = i + 1;
        };

        lowest
    }

    // Full position evaluation
    fun evaluate_position(board: &vector<u8>, black_king: u8, white_king: u8): u64 {
        let score: u64 = SCORE_OFFSET; // Start at offset so we can "subtract"

        let i: u64 = 0;
        while (i < 64) {
            let piece = *vector::borrow(board, i);
            let piece_type = piece & 7;
            let piece_color = piece & 8;

            if (piece_type != EMPTY) {
                let value = get_piece_value(piece_type);
                let row = (i / 8) as u8;
                let col = (i % 8) as u8;

                if (piece_color == BLACK) {
                    // Add value for black pieces
                    score = score + value;

                    // Positional bonuses for black
                    score = score + get_piece_square_bonus(piece_type, row, col, false);
                } else {
                    // Subtract value for white pieces
                    if (score > value) {
                        score = score - value;
                    };

                    // Subtract positional bonuses for white
                    let white_bonus = get_piece_square_bonus(piece_type, row, col, true);
                    if (score > white_bonus) {
                        score = score - white_bonus;
                    };
                };
            };
            i = i + 1;
        };

        // King safety
        let black_king_safety = evaluate_king_safety(board, black_king, false);
        let white_king_safety = evaluate_king_safety(board, white_king, true);
        score = score + black_king_safety;
        if (score > white_king_safety) {
            score = score - white_king_safety;
        };

        score
    }

    // Piece-square tables (simplified)
    fun get_piece_square_bonus(piece_type: u8, row: u8, col: u8, is_white: bool): u64 {
        // Flip row for white pieces (they want to advance up the board)
        let effective_row = if (is_white) { 7 - row } else { row };

        if (piece_type == PAWN) {
            // Pawns want to advance
            let advance_bonus = (effective_row as u64) * 10;
            // Center pawns are valuable
            let center_bonus: u64 = if ((col == 3 || col == 4) && (effective_row >= 3 && effective_row <= 5)) { 20 } else { 0 };
            return advance_bonus + center_bonus
        } else if (piece_type == KNIGHT) {
            // Knights want center, hate edges
            let edge_penalty: u64 = if (col == 0 || col == 7 || row == 0 || row == 7) { 0 } else { 20 };
            let center_bonus: u64 = if ((col >= 2 && col <= 5) && (row >= 2 && row <= 5)) { 20 } else { 0 };
            return edge_penalty + center_bonus
        } else if (piece_type == BISHOP) {
            // Bishops like diagonals and center
            let center_bonus: u64 = if ((col >= 2 && col <= 5) && (row >= 2 && row <= 5)) { 15 } else { 0 };
            return center_bonus
        } else if (piece_type == ROOK) {
            // Rooks on open files and 7th rank
            let seventh_rank: u64 = if (effective_row == 6) { 30 } else { 0 };
            return seventh_rank
        } else if (piece_type == QUEEN) {
            // Queen shouldn't come out too early, prefer safety
            let early_penalty: u64 = if (effective_row >= 5 && effective_row <= 7) { 0 } else { 10 };
            return early_penalty
        };

        0
    }

    // King safety evaluation
    fun evaluate_king_safety(board: &vector<u8>, king_pos: u8, is_white: bool): u64 {
        let safety: u64 = 0;
        let king_row = king_pos / 8;
        let king_col = king_pos % 8;

        // Bonus for castled position (king on g or c file)
        if ((king_col == 6 || king_col == 2) && ((is_white && king_row == 0) || (!is_white && king_row == 7))) {
            safety = safety + 50;
        };

        // Check pawn shield
        let pawn_color = if (is_white) { WHITE | PAWN } else { BLACK | PAWN };
        let shield_row = if (is_white) { king_row + 1 } else { if (king_row > 0) { king_row - 1 } else { 0 } };

        if (shield_row < 8) {
            // Check pawns in front of king
            let check_cols = vector[king_col];
            if (king_col > 0) { vector::push_back(&mut check_cols, king_col - 1); };
            if (king_col < 7) { vector::push_back(&mut check_cols, king_col + 1); };

            let j = 0;
            while (j < vector::length(&check_cols)) {
                let c = *vector::borrow(&check_cols, j);
                let sq = shield_row * 8 + c;
                let piece = *vector::borrow(board, (sq as u64));
                if ((piece & 15) == pawn_color) {
                    safety = safety + 15;
                };
                j = j + 1;
            };
        };

        safety
    }

    fun get_piece_value(piece_type: u8): u64 {
        if (piece_type == PAWN) { 100 }
        else if (piece_type == KNIGHT) { 320 }
        else if (piece_type == BISHOP) { 330 }
        else if (piece_type == ROOK) { 500 }
        else if (piece_type == QUEEN) { 900 }
        else if (piece_type == KING) { 20000 }
        else { 0 }
    }

    // ============ LEADERBOARD ============

    fun finalize_game(player: address) acquires Game, PlayerStats, Leaderboard {
        let game = borrow_global<Game>(player);
        let status = game.status;
        let move_count = game.move_count;

        let stats = borrow_global_mut<PlayerStats>(player);
        stats.games_played = stats.games_played + 1;

        if (status == STATUS_WHITE_WIN) {
            stats.wins = stats.wins + 1;
            stats.current_streak = stats.current_streak + 1;

            if (stats.current_streak > stats.best_streak) {
                stats.best_streak = stats.current_streak;
            };

            // Calculate points
            let base_points: u64 = 100;
            let time_bonus = if (move_count < 150) { (150 - move_count) * 2 } else { 0 };
            let streak_bonus = stats.current_streak * 10;

            stats.total_points = stats.total_points + base_points + time_bonus + streak_bonus;

            // Track fastest win
            if (stats.fastest_win_moves == 0 || move_count < stats.fastest_win_moves) {
                stats.fastest_win_moves = move_count;
            };
        } else if (status == STATUS_BLACK_WIN) {
            stats.losses = stats.losses + 1;
            stats.current_streak = 0;
        } else {
            // Draw or stalemate
            stats.draws = stats.draws + 1;
            stats.total_points = stats.total_points + 30;
        };

        // Update global leaderboard
        update_leaderboard(player, stats.total_points);
    }

    fun update_leaderboard(player: address, points: u64) acquires Leaderboard {
        if (!exists<Leaderboard>(@chess)) {
            return // Leaderboard not initialized - skip
        };

        let lb = borrow_global_mut<Leaderboard>(@chess);

        // Find if player already in leaderboard
        let len = vector::length(&lb.top_players);
        let player_idx: u64 = len;

        let i: u64 = 0;
        while (i < len) {
            if (*vector::borrow(&lb.top_players, i) == player) {
                player_idx = i;
                break
            };
            i = i + 1;
        };

        if (player_idx < len) {
            // Update existing entry
            *vector::borrow_mut(&mut lb.player_points, player_idx) = points;
        } else if (len < 100) {
            // Add new entry if room
            vector::push_back(&mut lb.top_players, player);
            vector::push_back(&mut lb.player_points, points);
        } else {
            // Check if player should replace lowest
            let min_idx: u64 = 0;
            let min_points = *vector::borrow(&lb.player_points, 0);

            i = 1;
            while (i < len) {
                let p = *vector::borrow(&lb.player_points, i);
                if (p < min_points) {
                    min_points = p;
                    min_idx = i;
                };
                i = i + 1;
            };

            if (points > min_points) {
                *vector::borrow_mut(&mut lb.top_players, min_idx) = player;
                *vector::borrow_mut(&mut lb.player_points, min_idx) = points;
            };
        };

        // Simple bubble sort to maintain order (good enough for 100 elements)
        let len = vector::length(&lb.top_players);
        if (len > 1) {
            let i: u64 = 0;
            while (i < len - 1) {
                let j: u64 = 0;
                while (j < len - 1 - i) {
                    let p1 = *vector::borrow(&lb.player_points, j);
                    let p2 = *vector::borrow(&lb.player_points, j + 1);
                    if (p2 > p1) {
                        // Swap
                        let addr1 = *vector::borrow(&lb.top_players, j);
                        let addr2 = *vector::borrow(&lb.top_players, j + 1);
                        *vector::borrow_mut(&mut lb.top_players, j) = addr2;
                        *vector::borrow_mut(&mut lb.top_players, j + 1) = addr1;
                        *vector::borrow_mut(&mut lb.player_points, j) = p2;
                        *vector::borrow_mut(&mut lb.player_points, j + 1) = p1;
                    };
                    j = j + 1;
                };
                i = i + 1;
            };
        };
    }

    // Initialize leaderboard (call once by deployer)
    public entry fun init_leaderboard(account: &signer) {
        let addr = signer::address_of(account);
        assert!(addr == @chess, 1); // Only deployer can initialize

        if (!exists<Leaderboard>(@chess)) {
            move_to(account, Leaderboard {
                top_players: vector::empty<address>(),
                player_points: vector::empty<u64>(),
            });
        };
    }

    // ============ HELPERS ============

    fun abs_diff(a: u8, b: u8): u8 {
        if (a > b) { a - b } else { b - a }
    }
}
