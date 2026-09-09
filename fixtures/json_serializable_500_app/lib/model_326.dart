import 'package:json_annotation/json_annotation.dart';

part 'model_326.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model326 {
  const Model326({required this.id, required this.value});

  final int id;
  final String value;

  factory Model326.fromJson(Map<String, dynamic> json) =>
      _$Model326FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model326ToJson(this);
}
