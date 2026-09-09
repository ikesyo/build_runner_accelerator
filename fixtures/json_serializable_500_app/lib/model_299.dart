import 'package:json_annotation/json_annotation.dart';

part 'model_299.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model299 {
  const Model299({required this.id, required this.value});

  final int id;
  final String value;

  factory Model299.fromJson(Map<String, dynamic> json) =>
      _$Model299FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model299ToJson(this);
}
