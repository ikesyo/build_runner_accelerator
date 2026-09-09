import 'package:json_annotation/json_annotation.dart';

part 'model_274.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model274 {
  const Model274({required this.id, required this.value});

  final int id;
  final String value;

  factory Model274.fromJson(Map<String, dynamic> json) =>
      _$Model274FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model274ToJson(this);
}
