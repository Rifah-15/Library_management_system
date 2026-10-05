-- phpMyAdmin SQL Dump
-- version 5.2.1
-- https://www.phpmyadmin.net/
--
-- Host: 127.0.0.1
-- Generation Time: Oct 05, 2026 at 12:43 PM
-- Server version: 10.4.32-MariaDB
-- PHP Version: 8.2.12

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `library_db`
--
CREATE DATABASE IF NOT EXISTS `library_db` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
USE `library_db`;

DELIMITER $$
--
-- Procedures
--
CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_ExpireReservations` ()   BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE v_id INT;
    DECLARE cur CURSOR FOR
        SELECT MIN(r.ReservationID) FROM Reservation r
        WHERE r.Status = 'Pending'
          AND fn_AvailableCopies(r.BookID) >
              (SELECT COUNT(*) FROM Reservation x WHERE x.BookID = r.BookID AND x.Status = 'Ready')
        GROUP BY r.BookID;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    UPDATE Reservation SET Status = 'Cancelled' WHERE Status = 'Ready' AND ExpiryDate < CURDATE();

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_id;
        IF done = 1 THEN
            LEAVE read_loop;
        END IF;
        UPDATE Reservation SET Status = 'Ready', ExpiryDate = DATE_ADD(CURDATE(), INTERVAL 3 DAY)
        WHERE ReservationID = v_id;
    END LOOP;
    CLOSE cur;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_IssueBook` (IN `p_copy` INT, IN `p_member` INT, IN `p_staff` INT)   BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE v_book INT;
    DECLARE v_ready INT;
    DECLARE v_issue INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT AccountStatus INTO v_status FROM Member WHERE MemberID = p_member;
    IF v_status IS NULL OR v_status <> 'Active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Member account is not active';
    END IF;

    IF EXISTS (SELECT 1 FROM vw_OverdueBooks v JOIN IssueRecord i ON v.IssueID = i.IssueID
               WHERE i.MemberID = p_member) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Member has overdue books. Return them first';
    END IF;

    IF fn_MemberDue(p_member) > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Member has unpaid fines. Clear them first';
    END IF;

    SELECT BookID INTO v_book FROM BookCopy WHERE CopyID = p_copy;
    SELECT COUNT(*) INTO v_ready FROM Reservation
    WHERE BookID = v_book AND MemberID <> p_member AND Status = 'Ready' AND ExpiryDate >= CURDATE();
    IF fn_AvailableCopies(v_book) <= v_ready THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Remaining copies are held for members who reserved this book';
    END IF;

    -- triggers set DueDate, check availability and book limit, mark the copy Issued
    INSERT INTO IssueRecord (CopyID, MemberID, StaffID, IssueDate)
    VALUES (p_copy, p_member, p_staff, CURDATE());
    SET v_issue = LAST_INSERT_ID();

    UPDATE Reservation SET Status = 'Completed'
    WHERE MemberID = p_member AND BookID = v_book AND Status IN ('Pending', 'Ready');

    COMMIT;
    SELECT v_issue AS IssueID, DueDate FROM IssueRecord WHERE IssueID = v_issue;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_PayFine` (IN `p_fine` INT, IN `p_amount` DECIMAL(6,2), IN `p_method` VARCHAR(30))   BEGIN
    DECLARE v_due DECIMAL(8,2);
    SET v_due = fn_FineDue(p_fine);
    IF v_due IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Fine not found';
    END IF;
    IF p_amount <= 0 OR p_amount > v_due THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Amount must be above 0 and not more than the amount due';
    END IF;
    INSERT INTO FinePayment (FineID, AmountPaid, PaymentMethod, ReferenceNo)
    VALUES (p_fine, p_amount, p_method, CONCAT('PAY-', UUID_SHORT()));
    SELECT fn_FineDue(p_fine) AS RemainingDue;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_RenewBook` (IN `p_issue` INT)   BEGIN
    DECLARE v_count INT;
    DECLARE v_max INT;
    DECLARE v_days INT;
    DECLARE v_overdue INT;
    DECLARE v_book INT;
    DECLARE v_member INT;

    SELECT i.RenewalCount, mt.MaxRenewals, mt.LoanPeriodDays, (i.DueDate < CURDATE()), bc.BookID, i.MemberID
    INTO v_count, v_max, v_days, v_overdue, v_book, v_member
    FROM IssueRecord i
    JOIN Member m      ON i.MemberID = m.MemberID
    JOIN MemberType mt ON m.MemberTypeID = mt.MemberTypeID
    JOIN BookCopy bc   ON i.CopyID = bc.CopyID
    WHERE i.IssueID = p_issue AND i.Status = 'Issued';

    IF v_count IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan not found or already returned';
    END IF;
    IF v_count >= v_max THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Renewal limit reached for this member type';
    END IF;
    IF v_overdue = 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Overdue books cannot be renewed';
    END IF;
    IF EXISTS (SELECT 1 FROM Reservation
               WHERE BookID = v_book AND MemberID <> v_member AND Status IN ('Pending', 'Ready')) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Another member has reserved this book';
    END IF;

    UPDATE IssueRecord
    SET DueDate = DATE_ADD(DueDate, INTERVAL v_days DAY), RenewalCount = RenewalCount + 1
    WHERE IssueID = p_issue;

    SELECT DueDate AS NewDueDate FROM IssueRecord WHERE IssueID = p_issue;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_ReserveBook` (IN `p_book` INT, IN `p_member` INT)   BEGIN
    DECLARE v_status VARCHAR(20);
    SELECT AccountStatus INTO v_status FROM Member WHERE MemberID = p_member;
    IF v_status IS NULL OR v_status <> 'Active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Member account is not active';
    END IF;
    IF fn_AvailableCopies(p_book) > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A copy is available now - issue it directly';
    END IF;
    INSERT INTO Reservation (BookID, MemberID) VALUES (p_book, p_member);  -- trigger blocks duplicates
    SELECT LAST_INSERT_ID() AS ReservationID;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_ReturnBook` (IN `p_issue` INT, IN `p_outcome` VARCHAR(10))   BEGIN
    DECLARE v_book INT;
    DECLARE v_copy INT;
    DECLARE v_res INT;
    DECLARE v_penalty DECIMAL(6,2) DEFAULT 0;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_outcome NOT IN ('Good', 'Damaged', 'Lost') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Outcome must be Good, Damaged or Lost';
    END IF;

    START TRANSACTION;

    SELECT bc.BookID, bc.CopyID INTO v_book, v_copy
    FROM IssueRecord i JOIN BookCopy bc ON i.CopyID = bc.CopyID
    WHERE i.IssueID = p_issue AND i.Status = 'Issued';
    IF v_copy IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan not found or already returned';
    END IF;

    -- triggers set ReturnDate, make the copy Available and create the late fine
    UPDATE IssueRecord SET Status = 'Returned' WHERE IssueID = p_issue;

    IF p_outcome = 'Damaged' THEN
        UPDATE BookCopy SET CopyStatus = 'Damaged', ConditionStatus = 'Damaged' WHERE CopyID = v_copy;
        SET v_penalty = 100.00;
    ELSEIF p_outcome = 'Lost' THEN
        UPDATE BookCopy SET CopyStatus = 'Lost' WHERE CopyID = v_copy;
        SET v_penalty = 300.00;
    ELSE
        -- oldest waiting reservation gets the book for 3 days
        SELECT ReservationID INTO v_res FROM Reservation
        WHERE BookID = v_book AND Status = 'Pending'
        ORDER BY ReservationDate, ReservationID LIMIT 1;
        IF v_res IS NOT NULL THEN
            UPDATE Reservation SET Status = 'Ready', ExpiryDate = DATE_ADD(CURDATE(), INTERVAL 3 DAY)
            WHERE ReservationID = v_res;
        END IF;
    END IF;

    IF v_penalty > 0 THEN
        INSERT INTO Fine (IssueID, Amount) VALUES (p_issue, v_penalty)
        ON DUPLICATE KEY UPDATE Amount = Amount + v_penalty;
    END IF;

    COMMIT;
    SELECT COALESCE((SELECT Amount FROM Fine WHERE IssueID = p_issue), 0) AS TotalFine;
END$$

--
-- Functions
--
CREATE DEFINER=`root`@`localhost` FUNCTION `fn_AvailableCopies` (`p_book` INT) RETURNS INT(11) READS SQL DATA BEGIN
    RETURN (SELECT COUNT(*) FROM BookCopy WHERE BookID = p_book AND CopyStatus = 'Available');
END$$

CREATE DEFINER=`root`@`localhost` FUNCTION `fn_CalculateFine` (`p_issue` INT) RETURNS DECIMAL(8,2) READS SQL DATA BEGIN
    DECLARE v_days INT;
    SELECT DATEDIFF(COALESCE(ReturnDate, CURDATE()), DueDate) INTO v_days
    FROM IssueRecord WHERE IssueID = p_issue;
    IF v_days IS NULL OR v_days <= 0 THEN
        RETURN 0;
    END IF;
    RETURN v_days * fn_FinePerDay();
END$$

CREATE DEFINER=`root`@`localhost` FUNCTION `fn_FineDue` (`p_fine` INT) RETURNS DECIMAL(8,2) READS SQL DATA BEGIN
    RETURN (SELECT f.Amount - COALESCE((SELECT SUM(AmountPaid) FROM FinePayment WHERE FineID = f.FineID), 0)
            FROM Fine f WHERE f.FineID = p_fine);
END$$

CREATE DEFINER=`root`@`localhost` FUNCTION `fn_FinePerDay` () RETURNS DECIMAL(6,2) DETERMINISTIC NO SQL BEGIN
    RETURN 5.00;
END$$

CREATE DEFINER=`root`@`localhost` FUNCTION `fn_MemberDue` (`p_member` INT) RETURNS DECIMAL(8,2) READS SQL DATA BEGIN
    RETURN (SELECT COALESCE(SUM(f.Amount - COALESCE(p.paid, 0)), 0)
            FROM Fine f
            JOIN IssueRecord i ON f.IssueID = i.IssueID
            LEFT JOIN (SELECT FineID, SUM(AmountPaid) AS paid FROM FinePayment GROUP BY FineID) p
                   ON p.FineID = f.FineID
            WHERE i.MemberID = p_member);
END$$

DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `auditlog`
--

CREATE TABLE `auditlog` (
  `LogID` int(11) NOT NULL,
  `EventTime` datetime DEFAULT current_timestamp(),
  `EventType` varchar(30) NOT NULL,
  `RefID` int(11) DEFAULT NULL,
  `Details` varchar(255) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data for table `auditlog`
--

INSERT INTO `auditlog` (`LogID`, `EventTime`, `EventType`, `RefID`, `Details`) VALUES
(1, '2026-10-05 14:45:53', 'RETURN', 18, 'Copy 3 returned by member 2'),
(2, '2026-10-05 14:52:38', 'RETURN', 17, 'Copy 1 returned by member 1'),
(3, '2026-10-05 15:22:15', 'ISSUE', 19, 'Copy 8 issued to member 2 by staff 1'),
(4, '2026-10-05 15:22:38', 'RETURN', 13, 'Copy 6 returned by member 1'),
(5, '2026-10-05 15:24:14', 'ISSUE', 20, 'Copy 6 issued to member 3 by staff 1'),
(6, '2026-10-05 15:25:25', 'PAYMENT', 1, '100.00 paid by Cash'),
(7, '2026-10-05 15:25:55', 'ISSUE', 21, 'Copy 2 issued to member 1 by staff 2');

-- --------------------------------------------------------

--
-- Table structure for table `author`
--

CREATE TABLE `author` (
  `AuthorID` int(11) NOT NULL,
  `Name` varchar(100) NOT NULL,
  `Biography` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data for table `author`
--

INSERT INTO `author` (`AuthorID`, `Name`, `Biography`) VALUES
(1, 'Humayun Ahmed', 'Renowned Bangladeshi novelist and filmmaker.'),
(2, 'Kazi Nazrul Islam', 'The national poet of Bangladesh.'),
(3, 'Zahir Raihan', 'Bangladeshi writer and filmmaker.'),
(4, 'Rabindranath Tagore', 'Nobel laureate poet and writer.');

-- --------------------------------------------------------

--
-- Table structure for table `book`
--

CREATE TABLE `book` (
  `BookID` int(11) NOT NULL,
  `ISBN` varchar(20) DEFAULT NULL,
  `Title` varchar(150) NOT NULL,
  `PublisherID` int(11) DEFAULT NULL,
  `Edition` varchar(30) DEFAULT NULL,
  `PublicationYear` int(11) DEFAULT NULL,
  `Language` varchar(30) DEFAULT NULL,
  `CategoryID` int(11) DEFAULT NULL,
  `Description` varchar(255) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data for table `book`
--

INSERT INTO `book` (`BookID`, `ISBN`, `Title`, `PublisherID`, `Edition`, `PublicationYear`, `Language`, `CategoryID`, `Description`) VALUES
(1, '978-1', 'Himu', 1, '1st', 1990, 'Bengali', 1, NULL),
(2, '978-2', 'Agnibina', 2, '1st', 1922, 'Bengali', 2, NULL),
(3, '978-3', 'Hajar Bachhar Dhore', 1, '2nd', 1964, 'Bengali', 1, NULL),
(4, '978-4', 'Sonar Tori', 3, '1st', 1894, 'Bengali', 2, NULL),
(5, NULL, 'Shubro Geche Bone', NULL, NULL, NULL, 'Bengali', 1, NULL);

-- --------------------------------------------------------

--
-- Table structure for table `bookauthor`
--

CREATE TABLE `bookauthor` (
  `BookID` int(11) NOT NULL,
  `AuthorID` int(11) NOT NULL,
  `AuthorOrder` int(11) DEFAULT 1
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data for table `bookauthor`
--

INSERT INTO `bookauthor` (`BookID`, `AuthorID`, `AuthorOrder`) VALUES
(1, 1, 1),
(2, 2, 1),
(3, 3, 1),
(4, 4, 1),
(5, 1, 1);

-- --------------------------------------------------------

--
-- Table structure for table `bookcopy`
--

CREATE TABLE `bookcopy` (
  `CopyID` int(11) NOT NULL,
  `BookID` int(11) NOT NULL,
  `Barcode` varchar(30) DEFAULT NULL,
  `ShelfID` int(11) DEFAULT NULL,
  `AcquisitionDate` date DEFAULT curdate(),
  `ConditionStatus` varchar(20) DEFAULT 'Good',
  `CopyStatus` varchar(20) DEFAULT 'Available'
) ;

--
-- Dumping data for table `bookcopy`
--

INSERT INTO `bookcopy` (`CopyID`, `BookID`, `Barcode`, `ShelfID`, `AcquisitionDate`, `ConditionStatus`, `CopyStatus`) VALUES
(1, 1, 'BC-1001', 1, '2026-10-05', 'Damaged', 'Damaged'),
(2, 1, 'BC-1002', 1, '2026-10-05', 'Good', 'Issued'),
(3, 2, 'BC-1003', 2, '2026-10-05', 'Good', 'Available'),
(4, 3, 'BC-1004', 1, '2026-10-05', 'Good', 'Available'),
(5, 3, 'BC-1005', 1, '2026-10-05', 'Good', 'Issued'),
(6, 4, 'BC-1006', 2, '2026-10-05', 'Good', 'Issued'),
(7, 1, 'BC-1007', 1, '2026-10-05', 'Good', 'Available'),
(8, 5, 'BC-1008', 1, '2026-10-05', 'Good', 'Issued'),
(9, 5, 'BC-1009', 1, '2026-10-05', 'Good', 'Available'),
(10, 5, 'BC-1010', 1, '2026-10-05', 'Good', 'Available');

-- --------------------------------------------------------

--
-- Table structure for table `category`
--

CREATE TABLE `category` (
  `CategoryID` int(11) NOT NULL,
  `CategoryName` varchar(50) NOT NULL,
  `Description` varchar(200) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data for table `category`
--

INSERT INTO `category` (`CategoryID`, `CategoryName`, `Description`) VALUES
(1, 'Novel', 'Fiction novels'),
(2, 'Poetry', 'Poetry collections');

-- --------------------------------------------------------

--
-- Table structure for table `fine`
--

CREATE TABLE `fine` (
  `FineID` int(11) NOT NULL,
  `IssueID` int(11) NOT NULL,
  `Amount` decimal(6,2) NOT NULL CHECK (`Amount` > 0),
  `FineDate` date DEFAULT curdate()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data for table `fine`
--

INSERT INTO `fine` (`FineID`, `IssueID`, `Amount`, `FineDate`) VALUES
(1, 17, 100.00, '2026-10-05');

-- --------------------------------------------------------

--
-- Table structure for table `finepayment`
--

CREATE TABLE `finepayment` (
  `PaymentID` int(11) NOT NULL,
  `FineID` int(11) NOT NULL,
  `PaymentDate` date DEFAULT curdate(),
  `AmountPaid` decimal(6,2) NOT NULL CHECK (`AmountPaid` > 0),
  `PaymentMethod` varchar(30) DEFAULT NULL,
  `ReferenceNo` varchar(50) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data for table `finepayment`
--

INSERT INTO `finepayment` (`PaymentID`, `FineID`, `PaymentDate`, `AmountPaid`, `PaymentMethod`, `ReferenceNo`) VALUES
(1, 1, '2026-10-05', 100.00, 'Cash', 'PAY-1791192325959');

--
-- Triggers `finepayment`
--
DELIMITER $$
CREATE TRIGGER `trg_audit_payment` AFTER INSERT ON `finepayment` FOR EACH ROW BEGIN
    INSERT INTO AuditLog (EventType, RefID, Details)
    VALUES ('PAYMENT', NEW.FineID, CONCAT(NEW.AmountPaid, ' paid by ', COALESCE(NEW.PaymentMethod, 'unknown')));
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `trg_pay_check` BEFORE INSERT ON `finepayment` FOR EACH ROW BEGIN
    IF NEW.AmountPaid > COALESCE(fn_FineDue(NEW.FineID), 0) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment is more than the amount due for this fine';
    END IF;
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `issuerecord`
--

CREATE TABLE `issuerecord` (
  `IssueID` int(11) NOT NULL,
  `CopyID` int(11) NOT NULL,
  `MemberID` int(11) NOT NULL,
  `StaffID` int(11) NOT NULL,
  `IssueDate` date NOT NULL,
  `DueDate` date DEFAULT NULL,
  `ReturnDate` date DEFAULT NULL,
  `RenewalCount` int(11) DEFAULT 0,
  `Status` varchar(20) DEFAULT 'Issued'
) ;

--
-- Dumping data for table `issuerecord`
--

INSERT INTO `issuerecord` (`IssueID`, `CopyID`, `MemberID`, `StaffID`, `IssueDate`, `DueDate`, `ReturnDate`, `RenewalCount`, `Status`) VALUES
(1, 1, 1, 1, '2026-09-15', '2026-09-29', '2026-10-05', 0, 'Returned'),
(2, 3, 1, 2, '2026-10-05', '2026-10-19', '2026-10-05', 0, 'Returned'),
(3, 2, 1, 2, '2026-10-05', '2026-10-19', '2026-10-05', 0, 'Returned'),
(4, 6, 1, 1, '2026-10-05', '2026-10-19', '2026-10-05', 0, 'Returned'),
(5, 1, 2, 1, '2026-10-05', '2026-10-19', '2026-10-05', 0, 'Returned'),
(6, 2, 3, 2, '2026-10-05', '2026-11-04', '2026-10-05', 0, 'Returned'),
(7, 3, 1, 2, '2026-10-05', '2026-10-19', '2026-10-05', 0, 'Returned'),
(8, 4, 1, 2, '2026-10-05', '2026-10-19', '2026-10-05', 0, 'Returned'),
(9, 5, 1, 2, '2026-10-05', '2026-10-19', '2026-10-05', 0, 'Returned'),
(10, 4, 1, 2, '2026-10-05', '2026-10-19', '2026-10-05', 0, 'Returned'),
(11, 1, 1, 2, '2026-10-05', '2026-10-19', '2026-10-05', 0, 'Returned'),
(12, 2, 1, 2, '2026-10-05', '2026-10-19', '2026-10-05', 0, 'Returned'),
(13, 6, 1, 1, '2026-10-05', '2026-10-19', '2026-10-05', 0, 'Returned'),
(14, 3, 1, 2, '2026-10-05', '2026-10-19', '2026-10-05', 0, 'Returned'),
(15, 4, 2, 2, '2026-10-05', '2026-10-19', '2026-10-05', 0, 'Returned'),
(16, 5, 1, 2, '2026-10-05', '2026-10-19', NULL, 0, 'Issued'),
(17, 1, 1, 2, '2026-10-05', '2026-10-19', '2026-10-05', 0, 'Returned'),
(18, 3, 2, 2, '2026-10-05', '2026-10-19', '2026-10-05', 0, 'Returned'),
(19, 8, 2, 1, '2026-10-05', '2026-10-19', NULL, 0, 'Issued'),
(20, 6, 3, 1, '2026-10-05', '2026-11-04', NULL, 0, 'Issued'),
(21, 2, 1, 2, '2026-10-05', '2026-10-19', NULL, 0, 'Issued');

--
-- Triggers `issuerecord`
--
DELIMITER $$
CREATE TRIGGER `trg_after_issue` AFTER INSERT ON `issuerecord` FOR EACH ROW BEGIN
    UPDATE BookCopy SET CopyStatus = 'Issued' WHERE CopyID = NEW.CopyID;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `trg_after_return` AFTER UPDATE ON `issuerecord` FOR EACH ROW BEGIN
    DECLARE v_late INT DEFAULT 0;
    IF NEW.Status = 'Returned' AND OLD.Status <> 'Returned' THEN
        SET v_late = GREATEST(DATEDIFF(NEW.ReturnDate, NEW.DueDate), 0);
        IF v_late > 0 THEN
            INSERT INTO Fine (IssueID, Amount) VALUES (NEW.IssueID, v_late * fn_FinePerDay())
            ON DUPLICATE KEY UPDATE Amount = Amount;
        END IF;
        UPDATE BookCopy SET CopyStatus = 'Damaged'
        WHERE CopyID = NEW.CopyID AND ConditionStatus = 'Damaged';
        INSERT INTO AuditLog (EventType, RefID, Details)
        VALUES ('RETURN', NEW.IssueID,
                CONCAT('Copy ', NEW.CopyID, ' returned by member ', NEW.MemberID,
                       IF(v_late > 0, CONCAT(', ', v_late, ' day(s) late'), '')));
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `trg_audit_issue` AFTER INSERT ON `issuerecord` FOR EACH ROW BEGIN
    INSERT INTO AuditLog (EventType, RefID, Details)
    VALUES ('ISSUE', NEW.IssueID,
            CONCAT('Copy ', NEW.CopyID, ' issued to member ', NEW.MemberID, ' by staff ', NEW.StaffID));
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `trg_on_return` BEFORE UPDATE ON `issuerecord` FOR EACH ROW BEGIN
    IF NEW.Status = 'Returned' AND OLD.Status <> 'Returned' THEN
        IF NEW.ReturnDate IS NULL THEN
            SET NEW.ReturnDate = CURDATE();
        END IF;
        UPDATE BookCopy SET CopyStatus = 'Available' WHERE CopyID = NEW.CopyID;
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `trg_set_duedate` BEFORE INSERT ON `issuerecord` FOR EACH ROW BEGIN
    DECLARE loan_days INT;
    DECLARE max_books INT;
    DECLARE current_loans INT;
    DECLARE copy_state VARCHAR(20);

    SELECT CopyStatus INTO copy_state FROM BookCopy WHERE CopyID = NEW.CopyID;
    IF copy_state <> 'Available' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This copy is not available for issue';
    END IF;

    SELECT mt.LoanPeriodDays, mt.MaxBooks INTO loan_days, max_books
    FROM Member m JOIN MemberType mt ON m.MemberTypeID = mt.MemberTypeID
    WHERE m.MemberID = NEW.MemberID;

    SELECT COUNT(*) INTO current_loans
    FROM IssueRecord
    WHERE MemberID = NEW.MemberID AND Status = 'Issued';
    IF current_loans >= max_books THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Member has reached the maximum book limit';
    END IF;

    SET NEW.DueDate = DATE_ADD(NEW.IssueDate, INTERVAL loan_days DAY);
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `member`
--

CREATE TABLE `member` (
  `MemberID` int(11) NOT NULL,
  `Name` varchar(100) NOT NULL,
  `Email` varchar(100) DEFAULT NULL,
  `Phone` varchar(20) DEFAULT NULL,
  `Address` varchar(200) DEFAULT NULL,
  `PasswordHash` varchar(255) DEFAULT NULL,
  `MembershipDate` date DEFAULT curdate(),
  `MemberTypeID` int(11) NOT NULL,
  `AccountStatus` varchar(20) DEFAULT 'Active'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data for table `member`
--

INSERT INTO `member` (`MemberID`, `Name`, `Email`, `Phone`, `Address`, `PasswordHash`, `MembershipDate`, `MemberTypeID`, `AccountStatus`) VALUES
(1, 'Maria Akter', 'maria@mail.com', '018xxxxxxx', 'Dhaka', NULL, '2026-10-05', 1, 'Active'),
(2, 'Rifah Tasfiah', 'rifah@mail.com', '017xxxxxxx', 'Dhaka', NULL, '2026-10-05', 1, 'Active'),
(3, 'Tanvir Hasan', 'tanvir@mail.com', '019xxxxxxx', 'Dhaka', NULL, '2026-10-05', 2, 'Active'),
(4, 'Mira', 'mira@gmail.com', '016xxxxxxxx', '', NULL, '2026-10-05', 1, 'Active');

--
-- Triggers `member`
--
DELIMITER $$
CREATE TRIGGER `trg_member_status_ins` BEFORE INSERT ON `member` FOR EACH ROW BEGIN
    IF NEW.AccountStatus NOT IN ('Active', 'Suspended', 'Inactive') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'AccountStatus must be Active, Suspended or Inactive';
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `trg_member_status_upd` BEFORE UPDATE ON `member` FOR EACH ROW BEGIN
    IF NEW.AccountStatus NOT IN ('Active', 'Suspended', 'Inactive') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'AccountStatus must be Active, Suspended or Inactive';
    END IF;
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `membertype`
--

CREATE TABLE `membertype` (
  `MemberTypeID` int(11) NOT NULL,
  `TypeName` varchar(30) NOT NULL,
  `MaxBooks` int(11) NOT NULL CHECK (`MaxBooks` > 0),
  `LoanPeriodDays` int(11) NOT NULL CHECK (`LoanPeriodDays` > 0),
  `MaxRenewals` int(11) NOT NULL DEFAULT 1 CHECK (`MaxRenewals` >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data for table `membertype`
--

INSERT INTO `membertype` (`MemberTypeID`, `TypeName`, `MaxBooks`, `LoanPeriodDays`, `MaxRenewals`) VALUES
(1, 'Student', 3, 14, 1),
(2, 'Teacher', 5, 30, 2),
(3, 'General', 2, 10, 0);

-- --------------------------------------------------------

--
-- Table structure for table `publisher`
--

CREATE TABLE `publisher` (
  `PublisherID` int(11) NOT NULL,
  `Name` varchar(100) NOT NULL,
  `Address` varchar(200) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data for table `publisher`
--

INSERT INTO `publisher` (`PublisherID`, `Name`, `Address`) VALUES
(1, 'Anyadin Prokashoni', 'Dhaka'),
(2, 'Kakoli Prokashoni', 'Dhaka'),
(3, 'Visva-Bharati', 'West Bengal');

-- --------------------------------------------------------

--
-- Table structure for table `reservation`
--

CREATE TABLE `reservation` (
  `ReservationID` int(11) NOT NULL,
  `BookID` int(11) NOT NULL,
  `MemberID` int(11) NOT NULL,
  `ReservationDate` date DEFAULT curdate(),
  `ExpiryDate` date DEFAULT NULL,
  `Status` varchar(20) DEFAULT 'Pending'
) ;

--
-- Dumping data for table `reservation`
--

INSERT INTO `reservation` (`ReservationID`, `BookID`, `MemberID`, `ReservationDate`, `ExpiryDate`, `Status`) VALUES
(2, 2, 3, '2026-10-05', '2026-10-08', 'Cancelled'),
(3, 2, 1, '2026-10-05', NULL, 'Pending'),
(4, 4, 1, '2026-10-05', NULL, 'Pending'),
(5, 4, 4, '2026-10-05', NULL, 'Pending');

--
-- Triggers `reservation`
--
DELIMITER $$
CREATE TRIGGER `trg_no_duplicate_reservation` BEFORE INSERT ON `reservation` FOR EACH ROW BEGIN
    DECLARE active_count INT;
    SELECT COUNT(*) INTO active_count
    FROM Reservation
    WHERE BookID = NEW.BookID
      AND MemberID = NEW.MemberID
      AND Status IN ('Pending', 'Ready');
    IF active_count > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Member already has an active reservation for this book';
    END IF;
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `shelf`
--

CREATE TABLE `shelf` (
  `ShelfID` int(11) NOT NULL,
  `Section` varchar(50) NOT NULL,
  `RackNumber` varchar(20) NOT NULL,
  `Floor` varchar(20) DEFAULT NULL,
  `Description` varchar(200) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data for table `shelf`
--

INSERT INTO `shelf` (`ShelfID`, `Section`, `RackNumber`, `Floor`, `Description`) VALUES
(1, 'Novel', 'R-01', '1st', NULL),
(2, 'Poetry', 'R-02', '1st', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `staff`
--

CREATE TABLE `staff` (
  `StaffID` int(11) NOT NULL,
  `Name` varchar(100) NOT NULL,
  `Designation` varchar(50) DEFAULT NULL,
  `Email` varchar(100) DEFAULT NULL,
  `Phone` varchar(20) DEFAULT NULL,
  `PasswordHash` varchar(255) DEFAULT NULL,
  `AccountStatus` varchar(20) DEFAULT 'Active'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data for table `staff`
--

INSERT INTO `staff` (`StaffID`, `Name`, `Designation`, `Email`, `Phone`, `PasswordHash`, `AccountStatus`) VALUES
(1, 'Misir Ali', 'Librarian', 'misir@lib.com', '018xxxxxxx', '03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4', 'Active'),
(2, 'Gora', 'Assistant Librarian', 'gora@lib.com', '017xxxxxxx', '03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4', 'Active');

--
-- Triggers `staff`
--
DELIMITER $$
CREATE TRIGGER `trg_staff_status_ins` BEFORE INSERT ON `staff` FOR EACH ROW BEGIN
    IF NEW.AccountStatus NOT IN ('Active', 'Suspended', 'Inactive') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'AccountStatus must be Active, Suspended or Inactive';
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `trg_staff_status_upd` BEFORE UPDATE ON `staff` FOR EACH ROW BEGIN
    IF NEW.AccountStatus NOT IN ('Active', 'Suspended', 'Inactive') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'AccountStatus must be Active, Suspended or Inactive';
    END IF;
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_activereservations`
-- (See below for the actual view)
--
CREATE TABLE `vw_activereservations` (
`ReservationID` int(11)
,`Title` varchar(150)
,`MemberName` varchar(100)
,`ReservationDate` date
,`ExpiryDate` date
,`Status` varchar(20)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_bookavailability`
-- (See below for the actual view)
--
CREATE TABLE `vw_bookavailability` (
`BookID` int(11)
,`Title` varchar(150)
,`ISBN` varchar(20)
,`Category` varchar(50)
,`Authors` mediumtext
,`TotalCopies` bigint(21)
,`AvailableCopies` decimal(23,0)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finecollection`
-- (See below for the actual view)
--
CREATE TABLE `vw_finecollection` (
`PaymentDate` date
,`Payments` bigint(21)
,`Collected` decimal(28,2)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_memberloanhistory`
-- (See below for the actual view)
--
CREATE TABLE `vw_memberloanhistory` (
`IssueID` int(11)
,`MemberID` int(11)
,`MemberName` varchar(100)
,`Title` varchar(150)
,`Barcode` varchar(30)
,`IssueDate` date
,`DueDate` date
,`ReturnDate` date
,`RenewalCount` int(11)
,`Status` varchar(20)
,`FineAmount` decimal(6,2)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_membersummary`
-- (See below for the actual view)
--
CREATE TABLE `vw_membersummary` (
`MemberID` int(11)
,`Name` varchar(100)
,`TypeName` varchar(30)
,`AccountStatus` varchar(20)
,`MaxBooks` int(11)
,`ActiveLoans` bigint(21)
,`UnpaidFines` decimal(8,2)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_outstandingfines`
-- (See below for the actual view)
--
CREATE TABLE `vw_outstandingfines` (
`FineID` int(11)
,`MemberID` int(11)
,`MemberName` varchar(100)
,`Title` varchar(150)
,`FineDate` date
,`Amount` decimal(6,2)
,`Paid` decimal(28,2)
,`AmountDue` decimal(29,2)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_overduebooks`
-- (See below for the actual view)
--
CREATE TABLE `vw_overduebooks` (
`IssueID` int(11)
,`Title` varchar(150)
,`MemberName` varchar(100)
,`IssueDate` date
,`DueDate` date
,`DaysOverdue` int(7)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_popularbooks`
-- (See below for the actual view)
--
CREATE TABLE `vw_popularbooks` (
`BookID` int(11)
,`Title` varchar(150)
,`TimesIssued` bigint(21)
);

-- --------------------------------------------------------

--
-- Structure for view `vw_activereservations`
--
DROP TABLE IF EXISTS `vw_activereservations`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_activereservations`  AS SELECT `r`.`ReservationID` AS `ReservationID`, `b`.`Title` AS `Title`, `m`.`Name` AS `MemberName`, `r`.`ReservationDate` AS `ReservationDate`, `r`.`ExpiryDate` AS `ExpiryDate`, `r`.`Status` AS `Status` FROM ((`reservation` `r` join `book` `b` on(`r`.`BookID` = `b`.`BookID`)) join `member` `m` on(`r`.`MemberID` = `m`.`MemberID`)) WHERE `r`.`Status` in ('Pending','Ready') ;

-- --------------------------------------------------------

--
-- Structure for view `vw_bookavailability`
--
DROP TABLE IF EXISTS `vw_bookavailability`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_bookavailability`  AS SELECT `b`.`BookID` AS `BookID`, `b`.`Title` AS `Title`, `b`.`ISBN` AS `ISBN`, `c`.`CategoryName` AS `Category`, (select group_concat(`a`.`Name` order by `ba`.`AuthorOrder` ASC separator ', ') from (`bookauthor` `ba` join `author` `a` on(`a`.`AuthorID` = `ba`.`AuthorID`)) where `ba`.`BookID` = `b`.`BookID`) AS `Authors`, count(`bc`.`CopyID`) AS `TotalCopies`, coalesce(sum(`bc`.`CopyStatus` = 'Available'),0) AS `AvailableCopies` FROM ((`book` `b` left join `category` `c` on(`b`.`CategoryID` = `c`.`CategoryID`)) left join `bookcopy` `bc` on(`bc`.`BookID` = `b`.`BookID`)) GROUP BY `b`.`BookID`, `b`.`Title`, `b`.`ISBN`, `c`.`CategoryName` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finecollection`
--
DROP TABLE IF EXISTS `vw_finecollection`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finecollection`  AS SELECT `finepayment`.`PaymentDate` AS `PaymentDate`, count(0) AS `Payments`, sum(`finepayment`.`AmountPaid`) AS `Collected` FROM `finepayment` GROUP BY `finepayment`.`PaymentDate` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_memberloanhistory`
--
DROP TABLE IF EXISTS `vw_memberloanhistory`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_memberloanhistory`  AS SELECT `i`.`IssueID` AS `IssueID`, `m`.`MemberID` AS `MemberID`, `m`.`Name` AS `MemberName`, `b`.`Title` AS `Title`, `bc`.`Barcode` AS `Barcode`, `i`.`IssueDate` AS `IssueDate`, `i`.`DueDate` AS `DueDate`, `i`.`ReturnDate` AS `ReturnDate`, `i`.`RenewalCount` AS `RenewalCount`, `i`.`Status` AS `Status`, coalesce(`f`.`Amount`,0) AS `FineAmount` FROM ((((`issuerecord` `i` join `member` `m` on(`i`.`MemberID` = `m`.`MemberID`)) join `bookcopy` `bc` on(`i`.`CopyID` = `bc`.`CopyID`)) join `book` `b` on(`bc`.`BookID` = `b`.`BookID`)) left join `fine` `f` on(`f`.`IssueID` = `i`.`IssueID`)) ;

-- --------------------------------------------------------

--
-- Structure for view `vw_membersummary`
--
DROP TABLE IF EXISTS `vw_membersummary`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_membersummary`  AS SELECT `m`.`MemberID` AS `MemberID`, `m`.`Name` AS `Name`, `mt`.`TypeName` AS `TypeName`, `m`.`AccountStatus` AS `AccountStatus`, `mt`.`MaxBooks` AS `MaxBooks`, (select count(0) from `issuerecord` `i` where `i`.`MemberID` = `m`.`MemberID` and `i`.`Status` = 'Issued') AS `ActiveLoans`, `fn_MemberDue`(`m`.`MemberID`) AS `UnpaidFines` FROM (`member` `m` join `membertype` `mt` on(`m`.`MemberTypeID` = `mt`.`MemberTypeID`)) ;

-- --------------------------------------------------------

--
-- Structure for view `vw_outstandingfines`
--
DROP TABLE IF EXISTS `vw_outstandingfines`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_outstandingfines`  AS SELECT `f`.`FineID` AS `FineID`, `m`.`MemberID` AS `MemberID`, `m`.`Name` AS `MemberName`, `b`.`Title` AS `Title`, `f`.`FineDate` AS `FineDate`, `f`.`Amount` AS `Amount`, coalesce(`p`.`paid`,0) AS `Paid`, `f`.`Amount`- coalesce(`p`.`paid`,0) AS `AmountDue` FROM (((((`fine` `f` join `issuerecord` `i` on(`f`.`IssueID` = `i`.`IssueID`)) join `member` `m` on(`i`.`MemberID` = `m`.`MemberID`)) join `bookcopy` `bc` on(`i`.`CopyID` = `bc`.`CopyID`)) join `book` `b` on(`bc`.`BookID` = `b`.`BookID`)) left join (select `finepayment`.`FineID` AS `FineID`,sum(`finepayment`.`AmountPaid`) AS `paid` from `finepayment` group by `finepayment`.`FineID`) `p` on(`p`.`FineID` = `f`.`FineID`)) WHERE `f`.`Amount` - coalesce(`p`.`paid`,0) > 0 ;

-- --------------------------------------------------------

--
-- Structure for view `vw_overduebooks`
--
DROP TABLE IF EXISTS `vw_overduebooks`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_overduebooks`  AS SELECT `i`.`IssueID` AS `IssueID`, `b`.`Title` AS `Title`, `m`.`Name` AS `MemberName`, `i`.`IssueDate` AS `IssueDate`, `i`.`DueDate` AS `DueDate`, to_days(curdate()) - to_days(`i`.`DueDate`) AS `DaysOverdue` FROM (((`issuerecord` `i` join `bookcopy` `bc` on(`i`.`CopyID` = `bc`.`CopyID`)) join `book` `b` on(`bc`.`BookID` = `b`.`BookID`)) join `member` `m` on(`i`.`MemberID` = `m`.`MemberID`)) WHERE `i`.`Status` = 'Issued' AND curdate() > `i`.`DueDate` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_popularbooks`
--
DROP TABLE IF EXISTS `vw_popularbooks`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_popularbooks`  AS SELECT `b`.`BookID` AS `BookID`, `b`.`Title` AS `Title`, count(`i`.`IssueID`) AS `TimesIssued` FROM ((`book` `b` left join `bookcopy` `bc` on(`bc`.`BookID` = `b`.`BookID`)) left join `issuerecord` `i` on(`i`.`CopyID` = `bc`.`CopyID`)) GROUP BY `b`.`BookID`, `b`.`Title` ORDER BY count(`i`.`IssueID`) DESC ;

--
-- Indexes for dumped tables
--

--
-- Indexes for table `auditlog`
--
ALTER TABLE `auditlog`
  ADD PRIMARY KEY (`LogID`);

--
-- Indexes for table `author`
--
ALTER TABLE `author`
  ADD PRIMARY KEY (`AuthorID`);

--
-- Indexes for table `book`
--
ALTER TABLE `book`
  ADD PRIMARY KEY (`BookID`),
  ADD UNIQUE KEY `ISBN` (`ISBN`),
  ADD KEY `PublisherID` (`PublisherID`),
  ADD KEY `CategoryID` (`CategoryID`),
  ADD KEY `idx_book_title` (`Title`);

--
-- Indexes for table `bookauthor`
--
ALTER TABLE `bookauthor`
  ADD PRIMARY KEY (`BookID`,`AuthorID`),
  ADD KEY `AuthorID` (`AuthorID`);

--
-- Indexes for table `bookcopy`
--
ALTER TABLE `bookcopy`
  ADD PRIMARY KEY (`CopyID`),
  ADD UNIQUE KEY `Barcode` (`Barcode`),
  ADD KEY `ShelfID` (`ShelfID`),
  ADD KEY `idx_copy_status` (`CopyStatus`),
  ADD KEY `idx_copy_book_status` (`BookID`,`CopyStatus`);

--
-- Indexes for table `category`
--
ALTER TABLE `category`
  ADD PRIMARY KEY (`CategoryID`),
  ADD UNIQUE KEY `CategoryName` (`CategoryName`);

--
-- Indexes for table `fine`
--
ALTER TABLE `fine`
  ADD PRIMARY KEY (`FineID`),
  ADD UNIQUE KEY `IssueID` (`IssueID`);

--
-- Indexes for table `finepayment`
--
ALTER TABLE `finepayment`
  ADD PRIMARY KEY (`PaymentID`),
  ADD UNIQUE KEY `ReferenceNo` (`ReferenceNo`),
  ADD KEY `idx_payment_fine` (`FineID`);

--
-- Indexes for table `issuerecord`
--
ALTER TABLE `issuerecord`
  ADD PRIMARY KEY (`IssueID`),
  ADD KEY `CopyID` (`CopyID`),
  ADD KEY `StaffID` (`StaffID`),
  ADD KEY `idx_issue_member_status` (`MemberID`,`Status`),
  ADD KEY `idx_issue_due` (`DueDate`);

--
-- Indexes for table `member`
--
ALTER TABLE `member`
  ADD PRIMARY KEY (`MemberID`),
  ADD UNIQUE KEY `Email` (`Email`),
  ADD KEY `MemberTypeID` (`MemberTypeID`),
  ADD KEY `idx_member_name` (`Name`);

--
-- Indexes for table `membertype`
--
ALTER TABLE `membertype`
  ADD PRIMARY KEY (`MemberTypeID`),
  ADD UNIQUE KEY `TypeName` (`TypeName`);

--
-- Indexes for table `publisher`
--
ALTER TABLE `publisher`
  ADD PRIMARY KEY (`PublisherID`),
  ADD UNIQUE KEY `Name` (`Name`);

--
-- Indexes for table `reservation`
--
ALTER TABLE `reservation`
  ADD PRIMARY KEY (`ReservationID`),
  ADD KEY `MemberID` (`MemberID`),
  ADD KEY `idx_res_book_status` (`BookID`,`Status`);

--
-- Indexes for table `shelf`
--
ALTER TABLE `shelf`
  ADD PRIMARY KEY (`ShelfID`);

--
-- Indexes for table `staff`
--
ALTER TABLE `staff`
  ADD PRIMARY KEY (`StaffID`),
  ADD UNIQUE KEY `Email` (`Email`);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `auditlog`
--
ALTER TABLE `auditlog`
  MODIFY `LogID` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=8;

--
-- AUTO_INCREMENT for table `author`
--
ALTER TABLE `author`
  MODIFY `AuthorID` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=5;

--
-- AUTO_INCREMENT for table `book`
--
ALTER TABLE `book`
  MODIFY `BookID` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=6;

--
-- AUTO_INCREMENT for table `bookcopy`
--
ALTER TABLE `bookcopy`
  MODIFY `CopyID` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `category`
--
ALTER TABLE `category`
  MODIFY `CategoryID` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;

--
-- AUTO_INCREMENT for table `fine`
--
ALTER TABLE `fine`
  MODIFY `FineID` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `finepayment`
--
ALTER TABLE `finepayment`
  MODIFY `PaymentID` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `issuerecord`
--
ALTER TABLE `issuerecord`
  MODIFY `IssueID` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `member`
--
ALTER TABLE `member`
  MODIFY `MemberID` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=5;

--
-- AUTO_INCREMENT for table `membertype`
--
ALTER TABLE `membertype`
  MODIFY `MemberTypeID` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=4;

--
-- AUTO_INCREMENT for table `publisher`
--
ALTER TABLE `publisher`
  MODIFY `PublisherID` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=4;

--
-- AUTO_INCREMENT for table `reservation`
--
ALTER TABLE `reservation`
  MODIFY `ReservationID` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `shelf`
--
ALTER TABLE `shelf`
  MODIFY `ShelfID` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;

--
-- AUTO_INCREMENT for table `staff`
--
ALTER TABLE `staff`
  MODIFY `StaffID` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;

--
-- Constraints for dumped tables
--

--
-- Constraints for table `book`
--
ALTER TABLE `book`
  ADD CONSTRAINT `book_ibfk_1` FOREIGN KEY (`PublisherID`) REFERENCES `publisher` (`PublisherID`),
  ADD CONSTRAINT `book_ibfk_2` FOREIGN KEY (`CategoryID`) REFERENCES `category` (`CategoryID`);

--
-- Constraints for table `bookauthor`
--
ALTER TABLE `bookauthor`
  ADD CONSTRAINT `bookauthor_ibfk_1` FOREIGN KEY (`BookID`) REFERENCES `book` (`BookID`),
  ADD CONSTRAINT `bookauthor_ibfk_2` FOREIGN KEY (`AuthorID`) REFERENCES `author` (`AuthorID`);

--
-- Constraints for table `bookcopy`
--
ALTER TABLE `bookcopy`
  ADD CONSTRAINT `bookcopy_ibfk_1` FOREIGN KEY (`BookID`) REFERENCES `book` (`BookID`),
  ADD CONSTRAINT `bookcopy_ibfk_2` FOREIGN KEY (`ShelfID`) REFERENCES `shelf` (`ShelfID`);

--
-- Constraints for table `fine`
--
ALTER TABLE `fine`
  ADD CONSTRAINT `fine_ibfk_1` FOREIGN KEY (`IssueID`) REFERENCES `issuerecord` (`IssueID`);

--
-- Constraints for table `finepayment`
--
ALTER TABLE `finepayment`
  ADD CONSTRAINT `finepayment_ibfk_1` FOREIGN KEY (`FineID`) REFERENCES `fine` (`FineID`);

--
-- Constraints for table `issuerecord`
--
ALTER TABLE `issuerecord`
  ADD CONSTRAINT `issuerecord_ibfk_1` FOREIGN KEY (`CopyID`) REFERENCES `bookcopy` (`CopyID`),
  ADD CONSTRAINT `issuerecord_ibfk_2` FOREIGN KEY (`MemberID`) REFERENCES `member` (`MemberID`),
  ADD CONSTRAINT `issuerecord_ibfk_3` FOREIGN KEY (`StaffID`) REFERENCES `staff` (`StaffID`);

--
-- Constraints for table `member`
--
ALTER TABLE `member`
  ADD CONSTRAINT `member_ibfk_1` FOREIGN KEY (`MemberTypeID`) REFERENCES `membertype` (`MemberTypeID`);

--
-- Constraints for table `reservation`
--
ALTER TABLE `reservation`
  ADD CONSTRAINT `reservation_ibfk_1` FOREIGN KEY (`BookID`) REFERENCES `book` (`BookID`),
  ADD CONSTRAINT `reservation_ibfk_2` FOREIGN KEY (`MemberID`) REFERENCES `member` (`MemberID`);

DELIMITER $$
--
-- Events
--
CREATE DEFINER=`root`@`localhost` EVENT `ev_expire_reservations` ON SCHEDULE EVERY 1 HOUR STARTS '2026-10-05 14:31:14' ON COMPLETION NOT PRESERVE ENABLE DO CALL sp_ExpireReservations()$$

DELIMITER ;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
