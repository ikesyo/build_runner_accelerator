import 'package:json_annotation/json_annotation.dart';

part 'model_031.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model031 {
  const Model031({required this.id, required this.value});

  final int id;
  final String value;

  factory Model031.fromJson(Map<String, dynamic> json) =>
      _$Model031FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model031ToJson(this);
}
