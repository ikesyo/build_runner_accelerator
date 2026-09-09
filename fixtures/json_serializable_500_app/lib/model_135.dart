import 'package:json_annotation/json_annotation.dart';

part 'model_135.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model135 {
  const Model135({required this.id, required this.value});

  final int id;
  final String value;

  factory Model135.fromJson(Map<String, dynamic> json) =>
      _$Model135FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model135ToJson(this);
}
