import 'package:json_annotation/json_annotation.dart';

part 'model_244.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model244 {
  const Model244({required this.id, required this.value});

  final int id;
  final String value;

  factory Model244.fromJson(Map<String, dynamic> json) =>
      _$Model244FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model244ToJson(this);
}
