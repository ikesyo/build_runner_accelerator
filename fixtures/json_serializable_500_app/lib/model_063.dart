import 'package:json_annotation/json_annotation.dart';

part 'model_063.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model063 {
  const Model063({required this.id, required this.value});

  final int id;
  final String value;

  factory Model063.fromJson(Map<String, dynamic> json) =>
      _$Model063FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model063ToJson(this);
}
