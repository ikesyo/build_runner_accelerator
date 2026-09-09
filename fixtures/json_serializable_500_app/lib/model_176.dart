import 'package:json_annotation/json_annotation.dart';

part 'model_176.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model176 {
  const Model176({required this.id, required this.value});

  final int id;
  final String value;

  factory Model176.fromJson(Map<String, dynamic> json) =>
      _$Model176FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model176ToJson(this);
}
