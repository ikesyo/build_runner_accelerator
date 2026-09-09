import 'package:json_annotation/json_annotation.dart';

part 'model_234.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model234 {
  const Model234({required this.id, required this.value});

  final int id;
  final String value;

  factory Model234.fromJson(Map<String, dynamic> json) =>
      _$Model234FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model234ToJson(this);
}
