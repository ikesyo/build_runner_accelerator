import 'package:json_annotation/json_annotation.dart';

part 'model_245.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model245 {
  const Model245({required this.id, required this.value});

  final int id;
  final String value;

  factory Model245.fromJson(Map<String, dynamic> json) =>
      _$Model245FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model245ToJson(this);
}
