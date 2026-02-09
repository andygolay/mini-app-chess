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

        check_diagonal_path(board, from, to)
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

    // Check if the diagonal path between from and to is clear (exclusive of endpoints)
    fun check_diagonal_path(board: &vector<u8>, from: u8, to: u8): bool {
        if (from >= 64 || to >= 64 || from == to) {
            return true
        };

        let from_row = from / 8;
        let from_col = from % 8;
        let to_row = to / 8;
        let to_col = to % 8;

        // Determine direction
        let row_step_positive = to_row > from_row;
        let col_step_positive = to_col > from_col;

        // Start one step from 'from'
        let curr_row = if (row_step_positive) { from_row + 1 } else { if (from_row > 0) { from_row - 1 } else { return true } };
        let curr_col = if (col_step_positive) { from_col + 1 } else { if (from_col > 0) { from_col - 1 } else { return true } };

        // Walk the diagonal until we reach 'to' (exclusive)
        while (curr_row != to_row && curr_col != to_col) {
            if (curr_row >= 8 || curr_col >= 8) {
                return true // Out of bounds, shouldn't happen with valid input
            };

            let sq = curr_row * 8 + curr_col;
            let piece = *vector::borrow(board, (sq as u64));
            if ((piece & 7) != EMPTY) {
                return false
            };

            // Step
            if (row_step_positive) {
                curr_row = curr_row + 1;
            } else {
                if (curr_row == 0) break;
                curr_row = curr_row - 1;
            };

            if (col_step_positive) {
                curr_col = curr_col + 1;
            } else {
                if (curr_col == 0) break;
                curr_col = curr_col - 1;
            };
        };

        true
    }

    // Check if the straight line path (horizontal or vertical) between from and to is clear
    fun is_line_clear(board: &vector<u8>, from: u8, to: u8): bool {
        if (from >= 64 || to >= 64 || from == to) {
            return true
        };

        let from_row = from / 8;
        let from_col = from % 8;
        let to_row = to / 8;
        let to_col = to % 8;

        if (from_row == to_row) {
            // Horizontal move - check columns between
            let min_col = if (from_col < to_col) { from_col } else { to_col };
            let max_col = if (from_col > to_col) { from_col } else { to_col };

            let col = min_col + 1;
            while (col < max_col) {
                let sq = from_row * 8 + col;
                let piece = *vector::borrow(board, (sq as u64));
                if ((piece & 7) != EMPTY) {
                    return false
                };
                col = col + 1;
            };
        } else if (from_col == to_col) {
            // Vertical move - check rows between
            let min_row = if (from_row < to_row) { from_row } else { to_row };
            let max_row = if (from_row > to_row) { from_row } else { to_row };

            let row = min_row + 1;
            while (row < max_row) {
                let sq = row * 8 + from_col;
                let piece = *vector::borrow(board, (sq as u64));
                if ((piece & 7) != EMPTY) {
                    return false
                };
                row = row + 1;
            };
        };
        // If neither horizontal nor vertical, just return true (shouldn't be called this way)

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
    // Alpha-beta minimax with quiescence search
    // Targets ~1500 Elo strength

    const SCORE_OFFSET: u64 = 100000; // Offset to handle "negative" scores with u64
    const MIN_SCORE: u64 = 0;
    const MAX_SCORE: u64 = 200000;
    const SEARCH_DEPTH: u8 = 3; // 3-ply search
    const QUIESCENCE_DEPTH: u8 = 2; // Full quiescence

    // Piece values in centipawns
    const PAWN_VALUE: u64 = 100;
    const KNIGHT_VALUE: u64 = 320;
    const BISHOP_VALUE: u64 = 330;
    const ROOK_VALUE: u64 = 500;
    const QUEEN_VALUE: u64 = 900;
    const KING_VALUE: u64 = 20000;

    fun generate_ai_move(game: &Game): Move {
        let best_from: u8 = 0;
        let best_to: u8 = 0;
        let best_promo: u8 = 0;
        let best_score: u64 = MIN_SCORE;
        let found_move = false;

        // Generate and sort moves (captures first for better pruning)
        let moves = generate_sorted_moves(&game.board, game.black_king_pos, game.white_king_pos, false);
        let num_moves = vector::length(&moves);
        let i: u64 = 0;

        while (i < num_moves) {
            let m = vector::borrow(&moves, i);
            let from = m.from_square;
            let to = m.to_square;
            let promo = m.promotion;

            if (is_valid_move(game, from, to, promo, false)) {
                // Make move on temp board
                let (temp_board, new_black_king, new_white_king) = make_temp_move(
                    &game.board, from, to, promo, game.black_king_pos, game.white_king_pos
                );

                // Search with alpha-beta
                let score = alpha_beta(
                    &temp_board,
                    SEARCH_DEPTH - 1,
                    MIN_SCORE,
                    MAX_SCORE,
                    true, // White's turn next (minimizing for black's perspective)
                    new_black_king,
                    new_white_king
                );

                // Add small tiebreaker for variety
                let tiebreaker = ((from as u64) * 7 + (to as u64) * 3 + game.move_count) % 5;
                score = score + tiebreaker;

                if (!found_move || score > best_score) {
                    best_score = score;
                    best_from = from;
                    best_to = to;
                    best_promo = promo;
                    found_move = true;
                };
            };
            i = i + 1;
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

    // Alpha-beta minimax search with Late Move Reductions (LMR)
    // Returns score from BLACK's perspective (higher = better for black)
    fun alpha_beta(
        board: &vector<u8>,
        depth: u8,
        alpha: u64,
        beta: u64,
        is_white_turn: bool,
        black_king: u8,
        white_king: u8
    ): u64 {
        // Base case: evaluate position
        if (depth == 0) {
            return quiescence_search(board, QUIESCENCE_DEPTH, alpha, beta, is_white_turn, black_king, white_king)
        };

        let mut_alpha = alpha;
        let mut_beta = beta;

        if (is_white_turn) {
            // White is minimizing (from black's perspective)
            let min_score = MAX_SCORE;
            let moves = generate_sorted_moves(board, black_king, white_king, true);
            let num_moves = vector::length(&moves);

            if (num_moves == 0) {
                // No moves - checkmate or stalemate
                if (is_square_attacked(board, white_king, false)) {
                    return MAX_SCORE - 1000 // Black wins (good for black)
                } else {
                    return SCORE_OFFSET // Stalemate
                }
            };

            let moves_searched: u64 = 0;
            let i: u64 = 0;
            while (i < num_moves) {
                let m = vector::borrow(&moves, i);
                let (temp_board, new_black_king, new_white_king) = make_temp_move(
                    board, m.from_square, m.to_square, m.promotion, black_king, white_king
                );

                // Skip if move leaves white in check
                if (!is_square_attacked(&temp_board, new_white_king, false)) {
                    let is_capture = m.captured_piece != EMPTY;
                    let search_depth = depth - 1;

                    // Late Move Reduction: reduce depth for late non-captures
                    // First 3 moves and captures get full depth
                    if (moves_searched >= 3 && !is_capture && depth >= 2) {
                        search_depth = depth - 2; // Reduce by 1 extra ply
                    };

                    let score = alpha_beta(&temp_board, search_depth, mut_alpha, mut_beta, false, new_black_king, new_white_king);

                    // Re-search with full depth if reduced search was interesting
                    if (search_depth < depth - 1 && score < mut_beta) {
                        score = alpha_beta(&temp_board, depth - 1, mut_alpha, mut_beta, false, new_black_king, new_white_king);
                    };

                    if (score < min_score) {
                        min_score = score;
                    };

                    if (score < mut_beta) {
                        mut_beta = score;
                    };

                    // Alpha cutoff
                    if (mut_beta <= mut_alpha) {
                        return min_score
                    };

                    moves_searched = moves_searched + 1;
                };
                i = i + 1;
            };
            min_score
        } else {
            // Black is maximizing
            let max_score = MIN_SCORE;
            let moves = generate_sorted_moves(board, black_king, white_king, false);
            let num_moves = vector::length(&moves);

            if (num_moves == 0) {
                // No moves - checkmate or stalemate
                if (is_square_attacked(board, black_king, true)) {
                    return MIN_SCORE + 1000 // White wins (bad for black)
                } else {
                    return SCORE_OFFSET // Stalemate
                }
            };

            let moves_searched: u64 = 0;
            let i: u64 = 0;
            while (i < num_moves) {
                let m = vector::borrow(&moves, i);
                let (temp_board, new_black_king, new_white_king) = make_temp_move(
                    board, m.from_square, m.to_square, m.promotion, black_king, white_king
                );

                // Skip if move leaves black in check
                if (!is_square_attacked(&temp_board, new_black_king, true)) {
                    let is_capture = m.captured_piece != EMPTY;
                    let search_depth = depth - 1;

                    // Late Move Reduction: reduce depth for late non-captures
                    if (moves_searched >= 3 && !is_capture && depth >= 2) {
                        search_depth = depth - 2;
                    };

                    let score = alpha_beta(&temp_board, search_depth, mut_alpha, mut_beta, true, new_black_king, new_white_king);

                    // Re-search with full depth if reduced search showed promise
                    if (search_depth < depth - 1 && score > mut_alpha) {
                        score = alpha_beta(&temp_board, depth - 1, mut_alpha, mut_beta, true, new_black_king, new_white_king);
                    };

                    if (score > max_score) {
                        max_score = score;
                    };

                    if (score > mut_alpha) {
                        mut_alpha = score;
                    };

                    // Beta cutoff
                    if (mut_beta <= mut_alpha) {
                        return max_score
                    };

                    moves_searched = moves_searched + 1;
                };
                i = i + 1;
            };
            max_score
        }
    }

    // Quiescence search - only search captures to reach quiet positions
    fun quiescence_search(
        board: &vector<u8>,
        depth: u8,
        alpha: u64,
        beta: u64,
        is_white_turn: bool,
        black_king: u8,
        white_king: u8
    ): u64 {
        // Static evaluation
        let stand_pat = evaluate_position_advanced(board, black_king, white_king);

        if (depth == 0) {
            return stand_pat
        };

        let mut_alpha = alpha;
        let mut_beta = beta;

        if (is_white_turn) {
            // White minimizing
            if (stand_pat < mut_beta) {
                mut_beta = stand_pat;
            };
            if (mut_beta <= mut_alpha) {
                return stand_pat
            };

            // Only search captures
            let captures = generate_captures(board, true);
            let num_captures = vector::length(&captures);
            let i: u64 = 0;

            while (i < num_captures) {
                let m = vector::borrow(&captures, i);
                let (temp_board, new_black_king, new_white_king) = make_temp_move(
                    board, m.from_square, m.to_square, m.promotion, black_king, white_king
                );

                if (!is_square_attacked(&temp_board, new_white_king, false)) {
                    let score = quiescence_search(&temp_board, depth - 1, mut_alpha, mut_beta, false, new_black_king, new_white_king);
                    if (score < mut_beta) {
                        mut_beta = score;
                    };
                    if (mut_beta <= mut_alpha) {
                        return mut_beta
                    };
                };
                i = i + 1;
            };
            mut_beta
        } else {
            // Black maximizing
            if (stand_pat > mut_alpha) {
                mut_alpha = stand_pat;
            };
            if (mut_beta <= mut_alpha) {
                return stand_pat
            };

            let captures = generate_captures(board, false);
            let num_captures = vector::length(&captures);
            let i: u64 = 0;

            while (i < num_captures) {
                let m = vector::borrow(&captures, i);
                let (temp_board, new_black_king, new_white_king) = make_temp_move(
                    board, m.from_square, m.to_square, m.promotion, black_king, white_king
                );

                if (!is_square_attacked(&temp_board, new_black_king, true)) {
                    let score = quiescence_search(&temp_board, depth - 1, mut_alpha, mut_beta, true, new_black_king, new_white_king);
                    if (score > mut_alpha) {
                        mut_alpha = score;
                    };
                    if (mut_beta <= mut_alpha) {
                        return mut_alpha
                    };
                };
                i = i + 1;
            };
            mut_alpha
        }
    }

    // Generate moves - piece-centric for efficiency (no 64x64 loops)
    fun generate_sorted_moves(board: &vector<u8>, black_king: u8, white_king: u8, is_white: bool): vector<Move> {
        let captures = vector::empty<Move>();
        let capture_scores = vector::empty<u64>();
        let non_captures = vector::empty<Move>();
        let color = if (is_white) { WHITE } else { BLACK };

        let from: u8 = 0;
        while (from < 64) {
            let piece = *vector::borrow(board, (from as u64));
            let piece_type = piece & 7;
            let piece_color = piece & 8;

            if (piece_type != EMPTY && piece_color == color) {
                // Generate moves based on piece type (piece-centric, not square-centric)
                generate_piece_moves(board, from, piece_type, is_white, color, &mut captures, &mut capture_scores, &mut non_captures);
            };
            from = from + 1;
        };

        // Simple insertion of high-value captures first (avoid full sort)
        // Just put queen captures at front
        let result = vector::empty<Move>();
        let i: u64 = 0;
        let num_captures = vector::length(&captures);

        // First pass: queen/rook captures (high value)
        while (i < num_captures) {
            let score = *vector::borrow(&capture_scores, i);
            if (score >= 5000) { // Queen or rook capture
                vector::push_back(&mut result, *vector::borrow(&captures, i));
            };
            i = i + 1;
        };
        // Second pass: other captures
        i = 0;
        while (i < num_captures) {
            let score = *vector::borrow(&capture_scores, i);
            if (score < 5000) {
                vector::push_back(&mut result, *vector::borrow(&captures, i));
            };
            i = i + 1;
        };

        // Add castling moves
        if (is_white) {
            if (can_castle_kingside_simple(board, white_king, true)) {
                vector::push_back(&mut result, Move {
                    from_square: white_king, to_square: white_king + 2, promotion: 0,
                    captured_piece: 0, is_castling: true, is_en_passant: false
                });
            };
            if (can_castle_queenside_simple(board, white_king, true)) {
                vector::push_back(&mut result, Move {
                    from_square: white_king, to_square: white_king - 2, promotion: 0,
                    captured_piece: 0, is_castling: true, is_en_passant: false
                });
            };
        } else {
            if (can_castle_kingside_simple(board, black_king, false)) {
                vector::push_back(&mut result, Move {
                    from_square: black_king, to_square: black_king + 2, promotion: 0,
                    captured_piece: 0, is_castling: true, is_en_passant: false
                });
            };
            if (can_castle_queenside_simple(board, black_king, false)) {
                vector::push_back(&mut result, Move {
                    from_square: black_king, to_square: black_king - 2, promotion: 0,
                    captured_piece: 0, is_castling: true, is_en_passant: false
                });
            };
        };

        // Add non-captures
        i = 0;
        while (i < vector::length(&non_captures)) {
            vector::push_back(&mut result, *vector::borrow(&non_captures, i));
            i = i + 1;
        };
        result
    }

    // Generate moves for a specific piece (piece-centric approach)
    fun generate_piece_moves(
        board: &vector<u8>,
        from: u8,
        piece_type: u8,
        is_white: bool,
        color: u8,
        captures: &mut vector<Move>,
        capture_scores: &mut vector<u64>,
        non_captures: &mut vector<Move>
    ) {
        let from_row = from / 8;
        let from_col = from % 8;

        if (piece_type == PAWN) {
            generate_pawn_moves(board, from, from_row, from_col, is_white, color, captures, capture_scores, non_captures);
        } else if (piece_type == KNIGHT) {
            generate_knight_moves(board, from, from_row, from_col, color, captures, capture_scores, non_captures);
        } else if (piece_type == BISHOP) {
            generate_sliding_moves(board, from, color, captures, capture_scores, non_captures, true, false);
        } else if (piece_type == ROOK) {
            generate_sliding_moves(board, from, color, captures, capture_scores, non_captures, false, true);
        } else if (piece_type == QUEEN) {
            generate_sliding_moves(board, from, color, captures, capture_scores, non_captures, true, true);
        } else if (piece_type == KING) {
            generate_king_moves(board, from, from_row, from_col, color, captures, capture_scores, non_captures);
        };
    }

    fun generate_pawn_moves(
        board: &vector<u8>,
        from: u8,
        from_row: u8,
        from_col: u8,
        is_white: bool,
        color: u8,
        captures: &mut vector<Move>,
        capture_scores: &mut vector<u64>,
        non_captures: &mut vector<Move>
    ) {
        let promo_row = if (is_white) { 7u8 } else { 0u8 };
        let _dir: u8 = if (is_white) { 8 } else { 0 }; // Direction offset (unused)
        let start_row = if (is_white) { 1u8 } else { 6u8 };

        // Forward move
        let to = if (is_white) { from + 8 } else { if (from >= 8) { from - 8 } else { 64 } };
        if (to < 64) {
            let target = *vector::borrow(board, (to as u64));
            if ((target & 7) == EMPTY) {
                add_pawn_move(from, to, to / 8, promo_row, captures, capture_scores, non_captures, 0);

                // Double push from start
                if (from_row == start_row) {
                    let to2 = if (is_white) { from + 16 } else { if (from >= 16) { from - 16 } else { 64 } };
                    if (to2 < 64) {
                        let target2 = *vector::borrow(board, (to2 as u64));
                        if ((target2 & 7) == EMPTY) {
                            vector::push_back(non_captures, Move {
                                from_square: from, to_square: to2, promotion: 0,
                                captured_piece: 0, is_castling: false, is_en_passant: false
                            });
                        };
                    };
                };
            };
        };

        // Captures (diagonal)
        let cap_targets = vector::empty<u8>();
        if (is_white) {
            if (from_col > 0 && from + 7 < 64) { vector::push_back(&mut cap_targets, from + 7); };
            if (from_col < 7 && from + 9 < 64) { vector::push_back(&mut cap_targets, from + 9); };
        } else {
            if (from_col > 0 && from >= 9) { vector::push_back(&mut cap_targets, from - 9); };
            if (from_col < 7 && from >= 7) { vector::push_back(&mut cap_targets, from - 7); };
        };

        let i = 0;
        while (i < vector::length(&cap_targets)) {
            let to = *vector::borrow(&cap_targets, i);
            let target = *vector::borrow(board, (to as u64));
            let target_type = target & 7;
            let target_color = target & 8;

            if (target_type != EMPTY && target_color != color) {
                add_pawn_move(from, to, to / 8, promo_row, captures, capture_scores, non_captures, target_type);
            };
            i = i + 1;
        };
    }

    fun add_pawn_move(
        from: u8, to: u8, to_row: u8, promo_row: u8,
        captures: &mut vector<Move>,
        capture_scores: &mut vector<u64>,
        non_captures: &mut vector<Move>,
        captured: u8
    ) {
        if (to_row == promo_row) {
            // Promotion - only queen for simplicity in AI (main line)
            let m = Move {
                from_square: from, to_square: to, promotion: QUEEN,
                captured_piece: captured, is_castling: false, is_en_passant: false
            };
            if (captured != EMPTY) {
                let score = get_piece_value(captured) * 10 + 900; // Pawn promoting
                vector::push_back(captures, m);
                vector::push_back(capture_scores, score);
            } else {
                vector::push_back(non_captures, m);
            };
        } else {
            let m = Move {
                from_square: from, to_square: to, promotion: 0,
                captured_piece: captured, is_castling: false, is_en_passant: false
            };
            if (captured != EMPTY) {
                let score = get_piece_value(captured) * 10 + (1000 - PAWN_VALUE);
                vector::push_back(captures, m);
                vector::push_back(capture_scores, score);
            } else {
                vector::push_back(non_captures, m);
            };
        };
    }

    fun generate_knight_moves(
        board: &vector<u8>,
        from: u8,
        from_row: u8,
        from_col: u8,
        color: u8,
        captures: &mut vector<Move>,
        capture_scores: &mut vector<u64>,
        non_captures: &mut vector<Move>
    ) {
        // Knight moves: 8 possible L-shapes - check each explicitly
        try_knight_move(board, from, from_row, from_col, 2, 1, true, true, color, captures, capture_scores, non_captures);
        try_knight_move(board, from, from_row, from_col, 2, 1, true, false, color, captures, capture_scores, non_captures);
        try_knight_move(board, from, from_row, from_col, 2, 1, false, true, color, captures, capture_scores, non_captures);
        try_knight_move(board, from, from_row, from_col, 2, 1, false, false, color, captures, capture_scores, non_captures);
        try_knight_move(board, from, from_row, from_col, 1, 2, true, true, color, captures, capture_scores, non_captures);
        try_knight_move(board, from, from_row, from_col, 1, 2, true, false, color, captures, capture_scores, non_captures);
        try_knight_move(board, from, from_row, from_col, 1, 2, false, true, color, captures, capture_scores, non_captures);
        try_knight_move(board, from, from_row, from_col, 1, 2, false, false, color, captures, capture_scores, non_captures);
    }

    fun try_knight_move(
        board: &vector<u8>,
        from: u8,
        from_row: u8,
        from_col: u8,
        dr: u8,
        dc: u8,
        row_pos: bool,
        col_pos: bool,
        color: u8,
        captures: &mut vector<Move>,
        capture_scores: &mut vector<u64>,
        non_captures: &mut vector<Move>
    ) {
        let to_row = if (row_pos) {
            from_row + dr
        } else {
            if (from_row >= dr) { from_row - dr } else { return }
        };
        let to_col = if (col_pos) {
            from_col + dc
        } else {
            if (from_col >= dc) { from_col - dc } else { return }
        };

        if (to_row >= 8 || to_col >= 8) { return };

        let to = to_row * 8 + to_col;
        let target = *vector::borrow(board, (to as u64));
        let target_type = target & 7;
        let target_color = target & 8;

        if (target_type == EMPTY) {
            vector::push_back(non_captures, Move {
                from_square: from, to_square: to, promotion: 0,
                captured_piece: 0, is_castling: false, is_en_passant: false
            });
        } else if (target_color != color) {
            let score = get_piece_value(target_type) * 10 + (1000 - KNIGHT_VALUE);
            vector::push_back(captures, Move {
                from_square: from, to_square: to, promotion: 0,
                captured_piece: target_type, is_castling: false, is_en_passant: false
            });
            vector::push_back(capture_scores, score);
        };
    }

    fun generate_sliding_moves(
        board: &vector<u8>,
        from: u8,
        color: u8,
        captures: &mut vector<Move>,
        capture_scores: &mut vector<u64>,
        non_captures: &mut vector<Move>,
        diagonal: bool,
        orthogonal: bool
    ) {
        let from_row = (from / 8) as u64;
        let from_col = (from % 8) as u64;
        let piece_val = if (diagonal && orthogonal) { QUEEN_VALUE }
                       else if (diagonal) { BISHOP_VALUE }
                       else { ROOK_VALUE };

        // Directions: 0=stay, 1=increase, 2=decrease
        if (diagonal) {
            slide_in_direction(board, from, from_row, from_col, 1, 1, color, piece_val, captures, capture_scores, non_captures); // +row +col
            slide_in_direction(board, from, from_row, from_col, 1, 2, color, piece_val, captures, capture_scores, non_captures); // +row -col
            slide_in_direction(board, from, from_row, from_col, 2, 1, color, piece_val, captures, capture_scores, non_captures); // -row +col
            slide_in_direction(board, from, from_row, from_col, 2, 2, color, piece_val, captures, capture_scores, non_captures); // -row -col
        };
        if (orthogonal) {
            slide_in_direction(board, from, from_row, from_col, 1, 0, color, piece_val, captures, capture_scores, non_captures); // +row
            slide_in_direction(board, from, from_row, from_col, 2, 0, color, piece_val, captures, capture_scores, non_captures); // -row
            slide_in_direction(board, from, from_row, from_col, 0, 1, color, piece_val, captures, capture_scores, non_captures); // +col
            slide_in_direction(board, from, from_row, from_col, 0, 2, color, piece_val, captures, capture_scores, non_captures); // -col
        };
    }

    // dr/dc: 0=no change, 1=increase, 2=decrease
    fun slide_in_direction(
        board: &vector<u8>,
        from: u8,
        from_row: u64,
        from_col: u64,
        dr: u8,
        dc: u8,
        color: u8,
        piece_val: u64,
        captures: &mut vector<Move>,
        capture_scores: &mut vector<u64>,
        non_captures: &mut vector<Move>
    ) {
        let r = from_row;
        let c = from_col;

        loop {
            // Move one step: 0=stay, 1=increase, 2=decrease
            if (dr == 1) { r = r + 1; } else if (dr == 2) { if (r == 0) { break }; r = r - 1; };
            if (dc == 1) { c = c + 1; } else if (dc == 2) { if (c == 0) { break }; c = c - 1; };

            if (r >= 8 || c >= 8) { break };

            let to = ((r * 8 + c) as u8);
            let target = *vector::borrow(board, (to as u64));
            let target_type = target & 7;
            let target_color = target & 8;

            if (target_type == EMPTY) {
                vector::push_back(non_captures, Move {
                    from_square: from, to_square: to, promotion: 0,
                    captured_piece: 0, is_castling: false, is_en_passant: false
                });
            } else {
                if (target_color != color) {
                    let score = get_piece_value(target_type) * 10 + (1000 - piece_val);
                    vector::push_back(captures, Move {
                        from_square: from, to_square: to, promotion: 0,
                        captured_piece: target_type, is_castling: false, is_en_passant: false
                    });
                    vector::push_back(capture_scores, score);
                };
                break // Blocked
            };
        };
    }

    fun generate_king_moves(
        board: &vector<u8>,
        from: u8,
        from_row: u8,
        from_col: u8,
        color: u8,
        captures: &mut vector<Move>,
        capture_scores: &mut vector<u64>,
        non_captures: &mut vector<Move>
    ) {
        // 8 adjacent squares
        let dr: u8 = 0;
        while (dr < 3) {
            let dc: u8 = 0;
            while (dc < 3) {
                if (dr != 1 || dc != 1) { // Skip center (the king's current position)
                    let to_row = if (dr == 0) { if (from_row > 0) { from_row - 1 } else { 255 } }
                                else if (dr == 2) { from_row + 1 }
                                else { from_row };
                    let to_col = if (dc == 0) { if (from_col > 0) { from_col - 1 } else { 255 } }
                                else if (dc == 2) { from_col + 1 }
                                else { from_col };

                    if (to_row < 8 && to_col < 8) {
                        let to = to_row * 8 + to_col;
                        let target = *vector::borrow(board, (to as u64));
                        let target_type = target & 7;
                        let target_color = target & 8;

                        if (target_type == EMPTY) {
                            vector::push_back(non_captures, Move {
                                from_square: from, to_square: to, promotion: 0,
                                captured_piece: 0, is_castling: false, is_en_passant: false
                            });
                        } else if (target_color != color) {
                            let score = get_piece_value(target_type) * 10 + (1000 - KING_VALUE);
                            vector::push_back(captures, Move {
                                from_square: from, to_square: to, promotion: 0,
                                captured_piece: target_type, is_castling: false, is_en_passant: false
                            });
                            vector::push_back(capture_scores, score);
                        };
                    };
                };
                dc = dc + 1;
            };
            dr = dr + 1;
        };
    }

    // Generate only capture moves for quiescence search (piece-centric)
    fun generate_captures(board: &vector<u8>, is_white: bool): vector<Move> {
        let captures = vector::empty<Move>();
        let capture_scores = vector::empty<u64>();
        let non_captures = vector::empty<Move>(); // Dummy, won't be used
        let color = if (is_white) { WHITE } else { BLACK };

        let from: u8 = 0;
        while (from < 64) {
            let piece = *vector::borrow(board, (from as u64));
            let piece_type = piece & 7;
            let piece_color = piece & 8;

            if (piece_type != EMPTY && piece_color == color) {
                generate_piece_moves(board, from, piece_type, is_white, color, &mut captures, &mut capture_scores, &mut non_captures);
            };
            from = from + 1;
        };

        // Return only captures (non_captures is discarded)
        captures
    }

    // Make a move on a temporary board
    fun make_temp_move(
        board: &vector<u8>,
        from: u8,
        to: u8,
        promo: u8,
        black_king: u8,
        white_king: u8
    ): (vector<u8>, u8, u8) {
        let temp_board = *board;
        let piece = *vector::borrow(&temp_board, (from as u64));
        let piece_type = piece & 7;
        let piece_color = piece & 8;

        // Execute move
        let new_piece = if (promo != 0) { piece_color | promo | HAS_MOVED } else { piece | HAS_MOVED };
        *vector::borrow_mut(&mut temp_board, (from as u64)) = EMPTY;
        *vector::borrow_mut(&mut temp_board, (to as u64)) = new_piece;

        // Handle castling
        if (piece_type == KING && abs_diff(from % 8, to % 8) == 2) {
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
        let captured = *vector::borrow(board, (to as u64)) & 7;
        if (piece_type == PAWN && (to % 8) != (from % 8) && captured == EMPTY) {
            if (piece_color == WHITE) {
                *vector::borrow_mut(&mut temp_board, ((to - 8) as u64)) = EMPTY;
            } else {
                *vector::borrow_mut(&mut temp_board, ((to + 8) as u64)) = EMPTY;
            };
        };

        // Update king positions
        let new_black_king = if (piece_type == KING && piece_color == BLACK) { to } else { black_king };
        let new_white_king = if (piece_type == KING && piece_color == WHITE) { to } else { white_king };

        (temp_board, new_black_king, new_white_king)
    }

    // Simplified castling check for move generation
    fun can_castle_kingside_simple(board: &vector<u8>, king_pos: u8, is_white: bool): bool {
        let row = if (is_white) { 0u8 } else { 7u8 };
        if (king_pos != row * 8 + 4) return false;

        let king = *vector::borrow(board, (king_pos as u64));
        if ((king & HAS_MOVED) != 0) return false;

        let rook_pos = row * 8 + 7;
        let rook = *vector::borrow(board, (rook_pos as u64));
        if ((rook & 7) != ROOK || (rook & HAS_MOVED) != 0) return false;

        // Check squares between are empty
        if (*vector::borrow(board, ((row * 8 + 5) as u64)) != EMPTY) return false;
        if (*vector::borrow(board, ((row * 8 + 6) as u64)) != EMPTY) return false;

        true
    }

    fun can_castle_queenside_simple(board: &vector<u8>, king_pos: u8, is_white: bool): bool {
        let row = if (is_white) { 0u8 } else { 7u8 };
        if (king_pos != row * 8 + 4) return false;

        let king = *vector::borrow(board, (king_pos as u64));
        if ((king & HAS_MOVED) != 0) return false;

        let rook_pos = row * 8;
        let rook = *vector::borrow(board, (rook_pos as u64));
        if ((rook & 7) != ROOK || (rook & HAS_MOVED) != 0) return false;

        // Check squares between are empty
        if (*vector::borrow(board, ((row * 8 + 1) as u64)) != EMPTY) return false;
        if (*vector::borrow(board, ((row * 8 + 2) as u64)) != EMPTY) return false;
        if (*vector::borrow(board, ((row * 8 + 3) as u64)) != EMPTY) return false;

        true
    }

    // Advanced position evaluation - optimized for VM limits
    fun evaluate_position_advanced(board: &vector<u8>, black_king: u8, white_king: u8): u64 {
        let score: u64 = SCORE_OFFSET;

        // Material count + piece-square tables
        let i: u64 = 0;
        while (i < 64) {
            let piece = *vector::borrow(board, i);
            let piece_type = piece & 7;
            let piece_color = piece & 8;

            if (piece_type != EMPTY) {
                let value = get_piece_value_advanced(piece_type);
                let row = (i / 8) as u8;
                let col = (i % 8) as u8;

                // Piece-square table bonus
                let psq_bonus = get_piece_square_value(piece_type, row, col, piece_color == WHITE);

                if (piece_color == BLACK) {
                    score = score + value + psq_bonus;
                } else {
                    if (score > value + psq_bonus) {
                        score = score - value - psq_bonus;
                    };
                };
            };
            i = i + 1;
        };

        // King safety (lightweight check)
        let black_safety = evaluate_king_safety_advanced(board, black_king, false);
        let white_safety = evaluate_king_safety_advanced(board, white_king, true);
        score = score + black_safety;
        if (score > white_safety) {
            score = score - white_safety;
        };

        // Removed expensive mobility counting - rely on move ordering instead

        score
    }

    fun get_piece_value_advanced(piece_type: u8): u64 {
        if (piece_type == PAWN) { PAWN_VALUE }
        else if (piece_type == KNIGHT) { KNIGHT_VALUE }
        else if (piece_type == BISHOP) { BISHOP_VALUE }
        else if (piece_type == ROOK) { ROOK_VALUE }
        else if (piece_type == QUEEN) { QUEEN_VALUE }
        else if (piece_type == KING) { KING_VALUE }
        else { 0 }
    }

    // Piece-square tables (simplified but effective)
    fun get_piece_square_value(piece_type: u8, row: u8, col: u8, is_white: bool): u64 {
        let r = if (is_white) { row } else { 7 - row };

        if (piece_type == PAWN) {
            // Pawns want to advance, center pawns more valuable
            let advance = (r as u64) * 10;
            let center = if (col >= 2 && col <= 5) { 10u64 } else { 0u64 };
            let double_center = if ((col == 3 || col == 4) && r >= 3) { 15u64 } else { 0u64 };
            return advance + center + double_center
        } else if (piece_type == KNIGHT) {
            // Knights love the center, hate corners
            let center_bonus = if (col >= 2 && col <= 5 && r >= 2 && r <= 5) { 30u64 } else { 0u64 };
            let corner_penalty = if ((col == 0 || col == 7) && (r == 0 || r == 7)) { 0u64 } else { 10u64 };
            return center_bonus + corner_penalty
        } else if (piece_type == BISHOP) {
            // Bishops like diagonals and center
            let center = if (col >= 2 && col <= 5 && r >= 2 && r <= 5) { 20u64 } else { 0u64 };
            return center
        } else if (piece_type == ROOK) {
            // Rooks on 7th rank and open files
            let seventh = if (r == 6) { 30u64 } else { 0u64 };
            return seventh
        } else if (piece_type == QUEEN) {
            // Queen shouldn't be too exposed early
            let early_out = if (r >= 2 && r <= 5) { 5u64 } else { 0u64 };
            return early_out
        } else if (piece_type == KING) {
            // King safety: castled position
            let castled = if ((col <= 2 || col >= 6) && r == 0) { 30u64 } else { 0u64 };
            return castled
        };
        0
    }

    fun evaluate_king_safety_advanced(board: &vector<u8>, king_pos: u8, is_white: bool): u64 {
        let safety: u64 = 0;
        let row = king_pos / 8;
        let col = king_pos % 8;

        // Bonus for castled position
        if ((col <= 2 || col >= 6) && ((is_white && row == 0) || (!is_white && row == 7))) {
            safety = safety + 40;
        };

        // Pawn shield
        let pawn_color = if (is_white) { WHITE } else { BLACK };
        let pawn_row = if (is_white) { row + 1 } else { if (row > 0) { row - 1 } else { 0 } };

        if (pawn_row < 8) {
            let start_col = if (col > 0) { col - 1 } else { 0 };
            let end_col = if (col < 7) { col + 1 } else { 7 };
            let c = start_col;
            while (c <= end_col) {
                let pos = pawn_row * 8 + c;
                let piece = *vector::borrow(board, (pos as u64));
                if ((piece & 7) == PAWN && (piece & 8) == pawn_color) {
                    safety = safety + 15;
                };
                c = c + 1;
            };
        };

        safety
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
            return row_diff == col_diff && row_diff > 0 && check_diagonal_path(board, from, to)
        } else if (piece_type == ROOK) {
            return (row_diff == 0 || col_diff == 0) && (row_diff + col_diff > 0) && is_line_clear(board, from, to)
        } else if (piece_type == QUEEN) {
            if (row_diff == col_diff && row_diff > 0) return check_diagonal_path(board, from, to);
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

            // Hybrid Elo-style: +25 base, +fast win bonus, +streak bonus
            let base_points: u64 = 25;
            // Fast win bonus: up to +15 for wins under 30 moves
            let fast_bonus = if (move_count < 30) { 15 }
                else if (move_count < 50) { 10 }
                else if (move_count < 80) { 5 }
                else { 0 };
            // Streak bonus: +2 per consecutive win (max +10)
            let streak_bonus = if (stats.current_streak > 5) { 10 } else { stats.current_streak * 2 };

            stats.total_points = stats.total_points + base_points + fast_bonus + streak_bonus;

            // Track fastest win
            if (stats.fastest_win_moves == 0 || move_count < stats.fastest_win_moves) {
                stats.fastest_win_moves = move_count;
            };
        } else if (status == STATUS_BLACK_WIN) {
            stats.losses = stats.losses + 1;
            stats.current_streak = 0;
            // Hybrid Elo-style: -5 for loss (can't go below 0)
            if (stats.total_points >= 5) {
                stats.total_points = stats.total_points - 5;
            } else {
                stats.total_points = 0;
            };
        } else {
            // Draw or stalemate: +10 points
            stats.draws = stats.draws + 1;
            stats.total_points = stats.total_points + 10;
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

    // ============ UNIT TESTS ============

    #[test]
    fun test_abs_diff() {
        assert!(abs_diff(5, 3) == 2, 0);
        assert!(abs_diff(3, 5) == 2, 1);
        assert!(abs_diff(0, 7) == 7, 2);
        assert!(abs_diff(7, 0) == 7, 3);
        assert!(abs_diff(4, 4) == 0, 4);
    }

    #[test]
    fun test_check_diagonal_path_empty_board() {
        let board = vector::empty<u8>();
        let i = 0;
        while (i < 64) {
            vector::push_back(&mut board, EMPTY);
            i = i + 1;
        };

        // a1 to h8 (0 to 63) - full diagonal, should be clear
        assert!(check_diagonal_path(&board, 0, 63) == true, 0);

        // h1 to a8 (7 to 56) - full diagonal other direction
        assert!(check_diagonal_path(&board, 7, 56) == true, 1);

        // Adjacent diagonal (e.g., 0 to 9)
        assert!(check_diagonal_path(&board, 0, 9) == true, 2);

        // c1 to f4 (2 to 29) - 3 steps diagonal
        assert!(check_diagonal_path(&board, 2, 29) == true, 3);

        // f4 to c1 (29 to 2) - reverse direction
        assert!(check_diagonal_path(&board, 29, 2) == true, 4);

        // g7 to b2 (54 to 9) - down-left diagonal
        assert!(check_diagonal_path(&board, 54, 9) == true, 5);

        // b2 to g7 (9 to 54) - up-right diagonal
        assert!(check_diagonal_path(&board, 9, 54) == true, 6);
    }

    #[test]
    fun test_check_diagonal_path_blocked() {
        let board = vector::empty<u8>();
        let i = 0;
        while (i < 64) {
            vector::push_back(&mut board, EMPTY);
            i = i + 1;
        };

        // Place a piece at d4 (27)
        *vector::borrow_mut(&mut board, 27) = WHITE | PAWN;

        // a1 to h8 should be blocked (passes through d4)
        // a1=0, b2=9, c3=18, d4=27, e5=36, f6=45, g7=54, h8=63
        assert!(check_diagonal_path(&board, 0, 63) == false, 0);

        // c3 to e5 should be blocked (d4 is in the way)
        assert!(check_diagonal_path(&board, 18, 36) == false, 1);

        // a1 to c3 should be clear (doesn't reach d4)
        assert!(check_diagonal_path(&board, 0, 18) == true, 2);

        // e5 to h8 should be clear (starts after d4)
        assert!(check_diagonal_path(&board, 36, 63) == true, 3);
    }

    #[test]
    fun test_check_diagonal_path_edge_cases() {
        let board = vector::empty<u8>();
        let i = 0;
        while (i < 64) {
            vector::push_back(&mut board, EMPTY);
            i = i + 1;
        };

        // Same square
        assert!(check_diagonal_path(&board, 28, 28) == true, 0);

        // Adjacent squares (1 step)
        assert!(check_diagonal_path(&board, 27, 36) == true, 1); // d4 to e5
        assert!(check_diagonal_path(&board, 36, 27) == true, 2); // e5 to d4
        assert!(check_diagonal_path(&board, 27, 18) == true, 3); // d4 to c3
        assert!(check_diagonal_path(&board, 27, 20) == true, 4); // d4 to e3

        // Corner to corner diagonals
        assert!(check_diagonal_path(&board, 0, 63) == true, 5);  // a1 to h8
        assert!(check_diagonal_path(&board, 63, 0) == true, 6);  // h8 to a1
        assert!(check_diagonal_path(&board, 7, 56) == true, 7);  // h1 to a8
        assert!(check_diagonal_path(&board, 56, 7) == true, 8);  // a8 to h1
    }

    #[test]
    fun test_is_line_clear_empty() {
        let board = vector::empty<u8>();
        let i = 0;
        while (i < 64) {
            vector::push_back(&mut board, EMPTY);
            i = i + 1;
        };

        // Horizontal: a1 to h1 (0 to 7)
        assert!(is_line_clear(&board, 0, 7) == true, 0);
        assert!(is_line_clear(&board, 7, 0) == true, 1);

        // Vertical: a1 to a8 (0 to 56)
        assert!(is_line_clear(&board, 0, 56) == true, 2);
        assert!(is_line_clear(&board, 56, 0) == true, 3);
    }

    #[test]
    fun test_init_board() {
        let board = init_board();
        assert!(vector::length(&board) == 64, 0);

        // Check white pieces on rank 1
        assert!(*vector::borrow(&board, 0) == (WHITE | ROOK), 1);
        assert!(*vector::borrow(&board, 4) == (WHITE | KING), 2);

        // Check black pieces on rank 8
        assert!(*vector::borrow(&board, 56) == (BLACK | ROOK), 3);
        assert!(*vector::borrow(&board, 60) == (BLACK | KING), 4);

        // Check pawns
        assert!(*vector::borrow(&board, 8) == (WHITE | PAWN), 5);
        assert!(*vector::borrow(&board, 48) == (BLACK | PAWN), 6);

        // Check empty squares
        assert!(*vector::borrow(&board, 28) == EMPTY, 7);
    }

    #[test]
    fun test_generate_piece_moves_knight() {
        let board = vector::empty<u8>();
        let i = 0;
        while (i < 64) {
            vector::push_back(&mut board, EMPTY);
            i = i + 1;
        };

        // Place white knight on d4 (27)
        *vector::borrow_mut(&mut board, 27) = WHITE | KNIGHT;

        let captures = vector::empty<Move>();
        let capture_scores = vector::empty<u64>();
        let non_captures = vector::empty<Move>();

        generate_piece_moves(&board, 27, KNIGHT, true, WHITE, &mut captures, &mut capture_scores, &mut non_captures);

        // Knight on d4 should have 8 moves: c2, e2, b3, f3, b5, f5, c6, e6
        // Squares: 10, 12, 17, 21, 33, 37, 42, 44
        assert!(vector::length(&non_captures) == 8, 0);
    }

    #[test]
    fun test_generate_piece_moves_bishop() {
        let board = vector::empty<u8>();
        let i = 0;
        while (i < 64) {
            vector::push_back(&mut board, EMPTY);
            i = i + 1;
        };

        // Place white bishop on d4 (27)
        *vector::borrow_mut(&mut board, 27) = WHITE | BISHOP;

        let captures = vector::empty<Move>();
        let capture_scores = vector::empty<u64>();
        let non_captures = vector::empty<Move>();

        generate_piece_moves(&board, 27, BISHOP, true, WHITE, &mut captures, &mut capture_scores, &mut non_captures);

        // Bishop on d4 should have 13 moves (diagonals in all directions)
        assert!(vector::length(&non_captures) == 13, 0);
    }

    #[test]
    fun test_check_diagonal_path_row_0_edge() {
        // Test diagonals starting from row 0
        let board = vector::empty<u8>();
        let i = 0;
        while (i < 64) {
            vector::push_back(&mut board, EMPTY);
            i = i + 1;
        };

        // From a1 (0) going up-right to h8 (63)
        assert!(check_diagonal_path(&board, 0, 63) == true, 0);

        // From h1 (7) going up-left to a8 (56)
        assert!(check_diagonal_path(&board, 7, 56) == true, 1);

        // From c1 (2) going up-right
        assert!(check_diagonal_path(&board, 2, 47) == true, 2);

        // From c1 (2) going up-left to a3 (16)
        assert!(check_diagonal_path(&board, 2, 16) == true, 3);
    }

    #[test]
    fun test_check_diagonal_path_col_0_edge() {
        // Test diagonals starting from col 0
        let board = vector::empty<u8>();
        let i = 0;
        while (i < 64) {
            vector::push_back(&mut board, EMPTY);
            i = i + 1;
        };

        // From a4 (24) going up-right to d7 (51)
        assert!(check_diagonal_path(&board, 24, 51) == true, 0);

        // From a4 (24) going down-right to c2 (10)
        assert!(check_diagonal_path(&board, 24, 10) == true, 1);

        // From a8 (56) going down-right to h1 (7)
        assert!(check_diagonal_path(&board, 56, 7) == true, 2);
    }

    #[test]
    fun test_check_diagonal_path_all_directions_from_center() {
        // Test all 4 diagonal directions from d4 (27)
        let board = vector::empty<u8>();
        let i = 0;
        while (i < 64) {
            vector::push_back(&mut board, EMPTY);
            i = i + 1;
        };

        // d4 = 27 (row 3, col 3)
        // Up-right: d4 to g7 (27 to 54)
        assert!(check_diagonal_path(&board, 27, 54) == true, 0);

        // Up-left: d4 to a7 (27 to 48)
        assert!(check_diagonal_path(&board, 27, 48) == true, 1);

        // Down-right: d4 to g1 (27 to 6)
        assert!(check_diagonal_path(&board, 27, 6) == true, 2);

        // Down-left: d4 to a1 (27 to 0)
        assert!(check_diagonal_path(&board, 27, 0) == true, 3);
    }

    #[test]
    fun test_ai_move_generation_from_start() {
        // Simulate what happens after e2-e4
        let board = init_board();

        // Make e2-e4 move (square 12 to 28)
        *vector::borrow_mut(&mut board, 12) = EMPTY;
        *vector::borrow_mut(&mut board, 28) = WHITE | PAWN | HAS_MOVED;

        // Now generate all black moves (what AI does)
        let moves = generate_sorted_moves(&board, 60, 4, false);

        // Should have legal moves for black
        assert!(vector::length(&moves) > 0, 0);

        // Validate each move doesn't crash
        let i: u64 = 0;
        let num_moves = vector::length(&moves);
        while (i < num_moves) {
            let m = vector::borrow(&moves, i);
            let piece = *vector::borrow(&board, (m.from_square as u64));
            let piece_type = piece & 7;

            // For bishops and queens, test check_diagonal_path doesn't crash
            if (piece_type == BISHOP || piece_type == QUEEN) {
                let from_row = m.from_square / 8;
                let from_col = m.from_square % 8;
                let to_row = m.to_square / 8;
                let to_col = m.to_square % 8;
                let row_diff = abs_diff(from_row, to_row);
                let col_diff = abs_diff(from_col, to_col);

                if (row_diff == col_diff && row_diff > 0) {
                    // This is a diagonal move - test it
                    let _clear = check_diagonal_path(&board, m.from_square, m.to_square);
                };
            };
            i = i + 1;
        };
    }

    #[test]
    fun test_is_valid_move_black_bishop() {
        // Test validating moves for black bishops in starting position
        let board = init_board();

        // Make e2-e4
        *vector::borrow_mut(&mut board, 12) = EMPTY;
        *vector::borrow_mut(&mut board, 28) = WHITE | PAWN | HAS_MOVED;

        // Create a mock game state for validation
        // Black bishop on c8 (58) - can't move (blocked by pawns)
        // Black bishop on f8 (61) - can't move (blocked by pawns)

        // Test that is_valid_bishop_move works without crashing
        // c8 to a6 would be a diagonal if not blocked
        let result = is_valid_bishop_move(&board, 58, 40);
        assert!(result == false, 0); // Should be blocked

        // f8 to h6 would be a diagonal if not blocked
        let result2 = is_valid_bishop_move(&board, 61, 47);
        assert!(result2 == false, 1); // Should be blocked
    }

    #[test]
    fun test_slide_in_direction_all_dirs() {
        // Test slide_in_direction in all 8 directions from center
        let board = vector::empty<u8>();
        let i = 0;
        while (i < 64) {
            vector::push_back(&mut board, EMPTY);
            i = i + 1;
        };

        let captures = vector::empty<Move>();
        let capture_scores = vector::empty<u64>();
        let non_captures = vector::empty<Move>();

        // From d4 (27), row=3, col=3
        // Test all diagonal directions (used by bishops/queens)
        slide_in_direction(&board, 27, 3, 3, 1, 1, WHITE, 330, &mut captures, &mut capture_scores, &mut non_captures); // +row +col
        slide_in_direction(&board, 27, 3, 3, 1, 2, WHITE, 330, &mut captures, &mut capture_scores, &mut non_captures); // +row -col
        slide_in_direction(&board, 27, 3, 3, 2, 1, WHITE, 330, &mut captures, &mut capture_scores, &mut non_captures); // -row +col
        slide_in_direction(&board, 27, 3, 3, 2, 2, WHITE, 330, &mut captures, &mut capture_scores, &mut non_captures); // -row -col

        // All moves should be generated without crashing
        assert!(vector::length(&non_captures) > 0, 0);
    }

    #[test]
    fun test_check_diagonal_path_non_diagonal_input() {
        // Test what happens if check_diagonal_path gets non-diagonal input
        // (This shouldn't happen in practice but tests the safety check)
        let board = vector::empty<u8>();
        let i = 0;
        while (i < 64) {
            vector::push_back(&mut board, EMPTY);
            i = i + 1;
        };

        // Horizontal move (not a diagonal) - a1 to h1
        let result = check_diagonal_path(&board, 0, 7);
        assert!(result == true, 0); // Should return true (let other validation handle it)

        // Vertical move (not a diagonal) - a1 to a8
        let result2 = check_diagonal_path(&board, 0, 56);
        assert!(result2 == true, 1);

        // Knight-like move (not a diagonal) - b1 to c3
        let result3 = check_diagonal_path(&board, 1, 18);
        assert!(result3 == true, 2);
    }

    #[test]
    fun test_check_diagonal_path_extreme_corners() {
        // Test all corner-to-corner diagonals
        let board = vector::empty<u8>();
        let i = 0;
        while (i < 64) {
            vector::push_back(&mut board, EMPTY);
            i = i + 1;
        };

        // a1 (0) to h8 (63) and reverse
        assert!(check_diagonal_path(&board, 0, 63) == true, 0);
        assert!(check_diagonal_path(&board, 63, 0) == true, 1);

        // h1 (7) to a8 (56) and reverse
        assert!(check_diagonal_path(&board, 7, 56) == true, 2);
        assert!(check_diagonal_path(&board, 56, 7) == true, 3);

        // Test from each corner to 2 squares in
        // a1 to c3
        assert!(check_diagonal_path(&board, 0, 18) == true, 4);
        // h1 to f3
        assert!(check_diagonal_path(&board, 7, 21) == true, 5);
        // a8 to c6
        assert!(check_diagonal_path(&board, 56, 42) == true, 6);
        // h8 to f6
        assert!(check_diagonal_path(&board, 63, 45) == true, 7);
    }
}
